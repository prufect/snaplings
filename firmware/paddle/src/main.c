/* Snaplings paddle: the XIAO nRF54L15 Sense, a second player's remote.
 *
 * It connects to the bridge (GB-Bridge, the XIAO ESP32S3) over Bluetooth and waits. When
 * the bridge opens a window, it streams its mic as ADPCM and reports how much it's being
 * shaken, then stops at the end of the window.
 *
 * Paddle to bridge: 'A' seq u16 predictor i16 index u8 nibbles..., 'S' tenths u16, 'E'.
 * Bridge to paddle: 'G' window_ms u16, 'X' to cancel.
 */

#include <math.h>
#include <string.h>
#include <zephyr/audio/dmic.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/byteorder.h>

LOG_MODULE_REGISTER(paddle, LOG_LEVEL_INF);

#define PADDLE_SERVICE_ENCODED BT_UUID_128_ENCODE(0x6b1f0001, 0x7a3c, 0x4c1e, 0x9b5e, 0x47616d65626f)
static const struct bt_uuid_128 paddle_service = BT_UUID_INIT_128(PADDLE_SERVICE_ENCODED);
static const struct bt_uuid_128 paddle_to_bridge =
	BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x6b1f0002, 0x7a3c, 0x4c1e, 0x9b5e, 0x47616d65626f));
static const struct bt_uuid_128 bridge_to_paddle =
	BT_UUID_INIT_128(BT_UUID_128_ENCODE(0x6b1f0003, 0x7a3c, 0x4c1e, 0x9b5e, 0x47616d65626f));

#define SAMPLE_RATE 16000
#define BLOCK_SAMPLES 800 /* 50 ms */
#define BLOCK_BYTES (BLOCK_SAMPLES * 2)
#define BLOCK_COUNT 8
#define PACKET_HEADER 6
#define PACKET_SIZE 244 /* What fits in one write at the 247-byte MTU we ask for. */
#define PACKET_SAMPLES ((PACKET_SIZE - PACKET_HEADER) * 2)

K_MEM_SLAB_DEFINE_STATIC(mic_slab, BLOCK_BYTES, BLOCK_COUNT, 4);

static const struct device *const dmic = DEVICE_DT_GET(DT_NODELABEL(pdm20));
static const struct i2c_dt_spec imu = I2C_DT_SPEC_GET(DT_NODELABEL(lsm6ds3tr_c));
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

static struct bt_conn *link;
static uint16_t write_handle;
static K_SEM_DEFINE(window_start, 0, 1);
static atomic_t window_ms;
static atomic_t window_cancelled;
static atomic_t window_open;
static atomic_t shake_tenths;

static void start_scan(void);

/* ---------- IMU ---------- */

#define IMU_CTRL1_XL 0x10
#define IMU_CTRL2_G 0x11
#define IMU_CTRL3_C 0x12
#define IMU_OUTX_L_G 0x22
#define ACCEL_16G 0x44    /* 104 Hz, +/-16 g */
#define GYRO_2000DPS 0x4C /* 104 Hz, +/-2000 dps */
#define ACCEL_G_PER_LSB (0.488f / 1000.0f)
#define GYRO_DPS_PER_LSB (70.0f / 1000.0f)
#define GYRO_DPS_FOR_ONE 500.0f /* How much spin counts the same as 1 g of shaking. */

static void imu_set_awake(bool awake)
{
	i2c_reg_write_byte_dt(&imu, IMU_CTRL3_C, 0x44); /* Update outputs in pairs, auto-increment. */
	i2c_reg_write_byte_dt(&imu, IMU_CTRL1_XL, awake ? ACCEL_16G : 0);
	i2c_reg_write_byte_dt(&imu, IMU_CTRL2_G, awake ? GYRO_2000DPS : 0);
}

/* Adds up how far the paddle is from sitting still, so harder and longer both count. */
static void shake_thread(void *a, void *b, void *c)
{
	for (;;) {
		if (!atomic_get(&window_open)) {
			k_msleep(10);
			continue;
		}
		float total = 0.0f;
		int64_t last = k_uptime_get();

		while (atomic_get(&window_open)) {
			uint8_t raw[12];

			if (i2c_burst_read_dt(&imu, IMU_OUTX_L_G, raw, sizeof(raw)) == 0) {
				int64_t now = k_uptime_get();
				float dt = (now - last) / 1000.0f;
				float gx = (int16_t)sys_get_le16(raw) * GYRO_DPS_PER_LSB;
				float gy = (int16_t)sys_get_le16(raw + 2) * GYRO_DPS_PER_LSB;
				float gz = (int16_t)sys_get_le16(raw + 4) * GYRO_DPS_PER_LSB;
				float ax = (int16_t)sys_get_le16(raw + 6) * ACCEL_G_PER_LSB;
				float ay = (int16_t)sys_get_le16(raw + 8) * ACCEL_G_PER_LSB;
				float az = (int16_t)sys_get_le16(raw + 10) * ACCEL_G_PER_LSB;
				float accel = fabsf(sqrtf(ax * ax + ay * ay + az * az) - 1.0f);
				float spin = sqrtf(gx * gx + gy * gy + gz * gz) / GYRO_DPS_FOR_ONE;

				/* Ignores the small readings a paddle has at rest. */
				if (accel > 0.15f || spin > 0.1f) {
					total += (accel + spin) * dt;
				}
				last = now;
				atomic_set(&shake_tenths, (atomic_val_t)MIN(total * 10.0f, 65535.0f));
			}
			k_msleep(10);
		}
	}
}

K_THREAD_DEFINE(shake_id, 1024, shake_thread, NULL, NULL, NULL, 6, 0, 0);

/* ---------- ADPCM ---------- */

static const int16_t ADPCM_STEPS[89] = {
	7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,    23,
	25,    28,    31,    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,
	88,    97,    107,   118,   130,   143,   157,   173,   190,   209,   230,   253,   279,
	307,   337,   371,   408,   449,   494,   544,   598,   658,   724,   796,   876,   963,
	1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,  2272,  2499,  2749,  3024,  3327,
	3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487,
	12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
static const int8_t ADPCM_INDEX[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};

static int adpcm_predicted;
static int adpcm_index;

static uint8_t adpcm_encode(int sample)
{
	int step = ADPCM_STEPS[adpcm_index];
	int diff = sample - adpcm_predicted;
	uint8_t nibble = 0;
	int change = step >> 3;

	if (diff < 0) {
		nibble = 8;
		diff = -diff;
	}
	if (diff >= step) {
		nibble |= 4;
		diff -= step;
		change += step;
	}
	if (diff >= step >> 1) {
		nibble |= 2;
		diff -= step >> 1;
		change += step >> 1;
	}
	if (diff >= step >> 2) {
		nibble |= 1;
		change += step >> 2;
	}
	adpcm_predicted += (nibble & 8) ? -change : change;
	adpcm_predicted = CLAMP(adpcm_predicted, -32768, 32767);
	adpcm_index = CLAMP(adpcm_index + ADPCM_INDEX[nibble], 0, 88);
	return nibble;
}

/* ---------- Sending ---------- */

static void send_packet(const uint8_t *data, uint16_t length)
{
	struct bt_conn *conn = link;

	if (conn && write_handle) {
		int err = bt_gatt_write_without_response(conn, write_handle, data, length, false);

		if (err) {
			LOG_WRN("write failed: %d", err);
		}
	}
}

static void send_shake(void)
{
	uint8_t packet[3] = {'S'};

	sys_put_le16((uint16_t)atomic_get(&shake_tenths), packet + 1);
	send_packet(packet, sizeof(packet));
}

/* ---------- One window ---------- */

static struct pcm_stream_cfg mic_stream = {
	.pcm_width = 16,
	.mem_slab = &mic_slab,
	.pcm_rate = SAMPLE_RATE,
	.block_size = BLOCK_BYTES,
};

static struct dmic_cfg mic_config = {
	.io = {.min_pdm_clk_freq = 1000000,
	       .max_pdm_clk_freq = 3500000,
	       .min_pdm_clk_dc = 40,
	       .max_pdm_clk_dc = 60},
	.streams = &mic_stream,
	.channel = {.req_num_streams = 1, .req_num_chan = 1},
};

static void run_window(uint32_t length_ms)
{
	static uint8_t packet[PACKET_SIZE];
	uint16_t seq = 0;
	int filled = 0;
	int64_t ends_at = k_uptime_get() + length_ms;
	int64_t next_shake = 0;

	atomic_set(&shake_tenths, 0);
	imu_set_awake(true);
	atomic_set(&window_open, 1);
	gpio_pin_set_dt(&led, 1);
	adpcm_predicted = 0;
	adpcm_index = 0;

	mic_config.channel.req_chan_map_lo = dmic_build_channel_map(0, 0, PDM_CHAN_LEFT);
	if (dmic_configure(dmic, &mic_config) || dmic_trigger(dmic, DMIC_TRIG_START)) {
		LOG_ERR("mic didn't start");
	}

	while (k_uptime_get() < ends_at && !atomic_get(&window_cancelled) && link) {
		void *block;
		size_t size;

		if (dmic_read(dmic, 0, &block, &size, 200)) {
			continue;
		}
		const int16_t *samples = block;

		for (size_t i = 0; i < size / 2; i++) {
			if (filled == 0) {
				memset(packet, 0, sizeof(packet));
				packet[0] = 'A';
				sys_put_le16(seq, packet + 1);
				sys_put_le16((uint16_t)(int16_t)adpcm_predicted, packet + 3);
				packet[5] = adpcm_index;
			}
			packet[PACKET_HEADER + filled / 2] |= adpcm_encode(samples[i]) << ((filled & 1) * 4);
			if (++filled == PACKET_SAMPLES) {
				send_packet(packet, PACKET_SIZE);
				seq++;
				filled = 0;
			}
		}
		k_mem_slab_free(&mic_slab, block);

		if (k_uptime_get() >= next_shake) {
			send_shake();
			next_shake = k_uptime_get() + 100;
		}
	}

	dmic_trigger(dmic, DMIC_TRIG_STOP);
	atomic_set(&window_open, 0);
	imu_set_awake(false);
	if (filled > 0) {
		send_packet(packet, PACKET_HEADER + (filled + 1) / 2);
	}
	send_shake();
	const uint8_t end = 'E';

	send_packet(&end, 1);
}

/* ---------- Bluetooth ---------- */

static uint8_t on_notify(struct bt_conn *conn, struct bt_gatt_subscribe_params *params,
			 const void *data, uint16_t length)
{
	if (!data) {
		params->value_handle = 0;
		return BT_GATT_ITER_STOP;
	}
	const uint8_t *bytes = data;

	if (bytes[0] == 'G' && length >= 3) {
		atomic_set(&window_ms, sys_get_le16(bytes + 1));
		atomic_set(&window_cancelled, 0);
		k_sem_give(&window_start);
	} else if (bytes[0] == 'X') {
		atomic_set(&window_cancelled, 1);
	}
	return BT_GATT_ITER_CONTINUE;
}

static struct bt_gatt_subscribe_params subscribe_params = {
	.notify = on_notify,
	.value = BT_GATT_CCC_NOTIFY,
};
static struct bt_gatt_discover_params discover_params;

static uint8_t on_discover(struct bt_conn *conn, const struct bt_gatt_attr *attr,
			   struct bt_gatt_discover_params *params)
{
	if (!attr) {
		if (subscribe_params.value_handle) {
			/* The bridge's notify value is followed straight away by its CCC. */
			subscribe_params.ccc_handle = subscribe_params.value_handle + 1;
			int err = bt_gatt_subscribe(conn, &subscribe_params);

			LOG_INF("ready, write %u notify %u (subscribe %d)", write_handle,
				subscribe_params.value_handle, err);
		} else {
			LOG_ERR("bridge has no paddle characteristics");
		}
		return BT_GATT_ITER_STOP;
	}
	const struct bt_gatt_chrc *chrc = attr->user_data;

	if (bt_uuid_cmp(chrc->uuid, &paddle_to_bridge.uuid) == 0) {
		write_handle = chrc->value_handle;
	} else if (bt_uuid_cmp(chrc->uuid, &bridge_to_paddle.uuid) == 0) {
		subscribe_params.value_handle = chrc->value_handle;
	}
	return BT_GATT_ITER_CONTINUE;
}

static void on_mtu(struct bt_conn *conn, uint8_t err, struct bt_gatt_exchange_params *params)
{
	LOG_INF("MTU %u (err %u)", bt_gatt_get_mtu(conn), err);
	discover_params.uuid = NULL;
	discover_params.func = on_discover;
	discover_params.start_handle = BT_ATT_FIRST_ATTRIBUTE_HANDLE;
	discover_params.end_handle = BT_ATT_LAST_ATTRIBUTE_HANDLE;
	discover_params.type = BT_GATT_DISCOVER_CHARACTERISTIC;
	bt_gatt_discover(conn, &discover_params);
}

static struct bt_gatt_exchange_params mtu_params = {.func = on_mtu};

static void on_connected(struct bt_conn *conn, uint8_t err)
{
	if (err) {
		LOG_WRN("connect failed: %u", err);
		bt_conn_unref(link);
		link = NULL;
		start_scan();
		return;
	}
	LOG_INF("connected");
	bt_conn_le_phy_update(conn, BT_CONN_LE_PHY_PARAM_2M);
	bt_conn_le_data_len_update(conn, BT_LE_DATA_LEN_PARAM_MAX);
	bt_gatt_exchange_mtu(conn, &mtu_params);
}

static void on_disconnected(struct bt_conn *conn, uint8_t reason)
{
	LOG_INF("disconnected: %u", reason);
	atomic_set(&window_cancelled, 1);
	write_handle = 0;
	subscribe_params.value_handle = 0;
	bt_conn_unref(link);
	link = NULL;
	start_scan();
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected = on_connected,
	.disconnected = on_disconnected,
};

static bool find_service(struct bt_data *data, void *user_data)
{
	bool *found = user_data;

	if ((data->type == BT_DATA_UUID128_ALL || data->type == BT_DATA_UUID128_SOME) &&
	    data->data_len >= BT_UUID_SIZE_128 &&
	    memcmp(data->data, paddle_service.val, BT_UUID_SIZE_128) == 0) {
		*found = true;
		return false;
	}
	return true;
}

static void on_scan(const bt_addr_le_t *addr, int8_t rssi, uint8_t type, struct net_buf_simple *ad)
{
	bool found = false;

	if (link) {
		return;
	}
	bt_data_parse(ad, find_service, &found);
	if (!found || bt_le_scan_stop()) {
		return;
	}
	/* 15-30 ms leaves room for the audio, and gives Wi-Fi turns on the bridge's radio. */
	const struct bt_le_conn_param *params = BT_LE_CONN_PARAM(12, 24, 0, 400);

	if (bt_conn_le_create(addr, BT_CONN_LE_CREATE_CONN, params, &link)) {
		start_scan();
	}
}

static void start_scan(void)
{
	int err = bt_le_scan_start(BT_LE_SCAN_ACTIVE, on_scan);

	if (err && err != -EALREADY) {
		LOG_ERR("scan failed: %d", err);
	}
}

int main(void)
{
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
	k_msleep(10); /* Lets the IMU finish powering up. */
	if (!i2c_is_ready_dt(&imu) || !device_is_ready(dmic)) {
		LOG_ERR("IMU or mic isn't ready");
	}
	imu_set_awake(false);

	int err = bt_enable(NULL);

	if (err) {
		LOG_ERR("Bluetooth failed: %d", err);
		return 0;
	}
	start_scan();
	LOG_INF("looking for the bridge");

	for (;;) {
		/* The LED blinks while looking for the bridge, and stays on during a window. */
		if (k_sem_take(&window_start, K_MSEC(link ? 2000 : 250)) == 0) {
			run_window(atomic_get(&window_ms));
		}
		gpio_pin_toggle_dt(&led);
	}
}
