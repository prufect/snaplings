// Magic Game Boy bridge: the XIAO ESP32S3 Sense on the R36S's OTG port.
// Carries the camera, mic and Wi-Fi for Snaplings over USB, and takes yells and shakes
// from the paddle over Bluetooth. Frames both ways: "GB" | type | length u32 LE | payload.
// Build and flash with firmware/build_bridge.sh, which writes config.h.

#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <ESP_I2S.h>
#include <HTTPClient.h>
#include <WiFi.h>
#include <esp_camera.h>
#include <esp_system.h>
#include <esp_wifi.h>

#include "config.h"  // WIFI_NAME, WIFI_PASSWORD and SERVER_URL.

enum : uint8_t {
  CMD_PREVIEW_ON = 0x01,
  CMD_PREVIEW_OFF = 0x02,
  CMD_SNAP = 0x03,
  CMD_MIC_ON = 0x04,
  CMD_MIC_OFF = 0x05,
  CMD_PING = 0x06,
  CMD_DUEL_START = 0x10,  // Payload: window in ms, then each move name on its own line.
  CMD_DUEL_STOP = 0x11,
  MSG_FRAME = 0x81,
  MSG_PHOTO = 0x82,
  MSG_TRANSCRIPT = 0x83,
  MSG_LEVEL = 0x84,
  MSG_SPRITE = 0x85,
  MSG_STATUS = 0x86,
  MSG_PONG = 0x87,
  MSG_PADDLE = 0x90,  // "1" when the paddle is connected, "0" when it isn't.
  MSG_SHAKE = 0x91,   // How much it has been shaken this window, u16 LE, in tenths.
  MSG_YELL = 0x92,    // The move's number (0 for none), a newline, then what was heard.
};

static const uint32_t MAX_COMMAND = 2048;
static const uint32_t SAMPLE_RATE = 16000;
static const uint32_t MIC_SECONDS = 30;
static const uint32_t MIN_RECORDING_MS = 500;
static const uint32_t YELL_SECONDS = 12;
static const uint32_t PADDLE_END_GRACE_MS = 1500;  // How long to wait for the paddle's end marker.

#define PADDLE_SERVICE "6b1f0001-7a3c-4c1e-9b5e-47616d65626f"
#define PADDLE_TO_BRIDGE "6b1f0002-7a3c-4c1e-9b5e-47616d65626f"
#define BRIDGE_TO_PADDLE "6b1f0003-7a3c-4c1e-9b5e-47616d65626f"

static SemaphoreHandle_t txLock;
static I2SClass mic;
static bool cameraOk = false, micOk = false;
static volatile bool previewOn = false;
static volatile bool recording = false;
static int16_t *micBuffer = nullptr;
static volatile size_t micSamples = 0;
static uint32_t micStartedAt = 0;

enum JobKind { JOB_SNAP, JOB_AUDIO, JOB_YELL };
static QueueHandle_t jobs;
static volatile bool jobRunning = false;

// The current duel window. The paddle's audio is decoded into yellBuffer as it arrives.
static BLECharacteristic *toPaddle = nullptr;
static volatile bool paddleConnected = false, paddleChanged = false;
static volatile bool duelOpen = false, paddleEnded = false, shakeChanged = false;
static volatile uint16_t shakeTenths = 0;
static int16_t *yellBuffer = nullptr;
static volatile size_t yellSamples = 0;
static uint32_t duelEndsAt = 0;
static uint16_t expectedSeq = 0;
static String duelMoves;

// ---------- USB frames ----------

static void writeAll(const uint8_t *data, size_t length) {
  uint32_t lastProgress = millis();
  while (length > 0) {
    size_t wrote = Serial.write(data, length);
    if (wrote > 0) {
      data += wrote;
      length -= wrote;
      lastProgress = millis();
    } else if (millis() - lastProgress > 1000) {
      return;  // Nothing is reading the port, so don't hold everything else up.
    } else {
      delay(1);
    }
  }
}

static void sendFrame(uint8_t type, const uint8_t *payload, size_t length) {
  uint8_t header[7] = {'G', 'B', type, uint8_t(length), uint8_t(length >> 8), uint8_t(length >> 16), uint8_t(length >> 24)};
  xSemaphoreTake(txLock, portMAX_DELAY);
  writeAll(header, sizeof(header));
  if (length > 0) writeAll(payload, length);
  Serial.flush();
  xSemaphoreGive(txLock);
}

static void sendStatus(const String &text) {
  sendFrame(MSG_STATUS, reinterpret_cast<const uint8_t *>(text.c_str()), text.length());
}

static void sendPaddle() {
  const uint8_t state = paddleConnected ? '1' : '0';
  sendFrame(MSG_PADDLE, &state, 1);
}

// ---------- Camera ----------

static bool startCamera() {
  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = 15;
  config.pin_d1 = 17;
  config.pin_d2 = 18;
  config.pin_d3 = 16;
  config.pin_d4 = 14;
  config.pin_d5 = 12;
  config.pin_d6 = 11;
  config.pin_d7 = 48;
  config.pin_xclk = 10;
  config.pin_pclk = 13;
  config.pin_vsync = 38;
  config.pin_href = 47;
  config.pin_sccb_sda = 40;
  config.pin_sccb_scl = 39;
  config.pin_pwdn = -1;
  config.pin_reset = -1;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_VGA;  // Sets the buffer size, so it has to be the largest we use.
  config.jpeg_quality = 12;
  config.fb_count = 2;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.grab_mode = CAMERA_GRAB_LATEST;
  if (esp_camera_init(&config) != ESP_OK) return false;
  esp_camera_sensor_get()->set_framesize(esp_camera_sensor_get(), FRAMESIZE_QVGA);
  return true;
}

static void sendPreviewFrame() {
  camera_fb_t *frame = esp_camera_fb_get();
  if (!frame) return;
  sendFrame(MSG_FRAME, frame->buf, frame->len);
  esp_camera_fb_return(frame);
}

static camera_fb_t *takePhoto() {
  sensor_t *sensor = esp_camera_sensor_get();
  sensor->set_framesize(sensor, FRAMESIZE_VGA);
  camera_fb_t *frame = nullptr;
  for (int i = 0; i < 3; i++) {  // The first frames after a size change are still the old size.
    if (frame) esp_camera_fb_return(frame);
    frame = esp_camera_fb_get();
  }
  return frame;
}

static void finishPhoto(camera_fb_t *frame) {
  if (frame) esp_camera_fb_return(frame);
  sensor_t *sensor = esp_camera_sensor_get();
  sensor->set_framesize(sensor, FRAMESIZE_QVGA);
}

// ---------- Talking to the server ----------

struct Reply {
  uint8_t *data = nullptr;
  size_t length = 0;
  ~Reply() { free(data); }
};

// Sends an upload and reads the whole answer. On failure, returns false and says why.
static bool post(const char *path, const char *type, const uint8_t *body, size_t length, const String &moves, Reply &reply,
                 String &problem) {
  if (WiFi.status() != WL_CONNECTED) {
    problem = "error: no wifi";
    return false;
  }
  WiFiClient client;
  HTTPClient http;
  http.begin(client, String(SERVER_URL) + path);
  http.setConnectTimeout(5000);
  http.setTimeout(60000);
  http.addHeader("Content-Type", type);
  if (moves.length() > 0) http.addHeader("X-Moves", moves);
  int code = http.POST(const_cast<uint8_t *>(body), length);
  if (code != 200) {
    problem = String("error: ") + path + " returned " + code;
    http.end();
    return false;
  }
  int size = http.getSize();
  if (size < 0 || size > 4 * 1024 * 1024) {
    problem = String("error: bad ") + path + " reply";
    http.end();
    return false;
  }
  reply.data = static_cast<uint8_t *>(ps_malloc(size + 1));
  WiFiClient *stream = http.getStreamPtr();
  size_t got = 0;
  uint32_t lastData = millis();
  while (reply.data && got < size_t(size) && millis() - lastData < 10000) {
    size_t available = stream->available();
    if (available) {
      got += stream->readBytes(reply.data + got, min(available, size_t(size) - got));
      lastData = millis();
    } else {
      delay(1);
    }
  }
  http.end();
  if (!reply.data || got != size_t(size)) {
    problem = String("error: bad ") + path + " reply";
    return false;
  }
  reply.length = got;
  reply.data[got] = 0;
  return true;
}

static uint8_t *makeWav(const int16_t *samples, size_t count, size_t &size) {
  const uint32_t bytes = count * 2;
  size = 44 + bytes;
  uint8_t *wav = static_cast<uint8_t *>(ps_malloc(size));
  if (!wav) return nullptr;
  const uint32_t riffSize = 36 + bytes, formatSize = 16, byteRate = SAMPLE_RATE * 2;
  const uint16_t pcm = 1, channels = 1, blockAlign = 2, bits = 16;
  memcpy(wav, "RIFF", 4);
  memcpy(wav + 4, &riffSize, 4);
  memcpy(wav + 8, "WAVEfmt ", 8);
  memcpy(wav + 16, &formatSize, 4);
  memcpy(wav + 20, &pcm, 2);
  memcpy(wav + 22, &channels, 2);
  memcpy(wav + 24, &SAMPLE_RATE, 4);
  memcpy(wav + 28, &byteRate, 4);
  memcpy(wav + 32, &blockAlign, 2);
  memcpy(wav + 34, &bits, 2);
  memcpy(wav + 36, "data", 4);
  memcpy(wav + 40, &bytes, 4);
  memcpy(wav + 44, samples, bytes);
  return wav;
}

static void runSnap() {
  camera_fb_t *frame = cameraOk ? takePhoto() : nullptr;
  if (!frame) {
    sendStatus(cameraOk ? "error: photo capture failed" : "error: camera not available");
    finishPhoto(nullptr);
    return;
  }
  sendFrame(MSG_PHOTO, frame->buf, frame->len);
  sendStatus("drawing");
  Reply reply;
  String problem;
  if (post("/photo", "image/jpeg", frame->buf, frame->len, "", reply, problem)) {
    sendFrame(MSG_SPRITE, reply.data, reply.length);
  } else {
    sendStatus(problem);
  }
  finishPhoto(frame);
}

static void runAudio() {
  size_t size;
  uint8_t *wav = makeWav(micBuffer, micSamples, size);
  if (!wav) {
    sendStatus("error: out of memory");
    return;
  }
  sendStatus("thinking");
  Reply reply;
  String problem;
  bool ok = post("/audio", "audio/wav", wav, size, "", reply, problem);
  free(wav);
  if (!ok) {
    sendStatus(problem);
    return;
  }
  uint8_t *newline = static_cast<uint8_t *>(memchr(reply.data, '\n', reply.length));
  if (!newline) {
    sendStatus("error: bad /audio reply");
    return;
  }
  sendFrame(MSG_TRANSCRIPT, reply.data, newline - reply.data);
  sendFrame(MSG_LEVEL, newline + 1, reply.data + reply.length - newline - 1);
}

// Always answers, so the game never waits for a yell that isn't coming.
static void runYell() {
  size_t size;
  uint8_t *wav = yellSamples > 0 ? makeWav(yellBuffer, yellSamples, size) : nullptr;
  Reply reply;
  String problem;
  bool ok = wav && post("/yell", "audio/wav", wav, size, duelMoves, reply, problem);
  free(wav);
  if (ok) {
    sendFrame(MSG_YELL, reply.data, reply.length);
  } else {
    sendFrame(MSG_YELL, reinterpret_cast<const uint8_t *>("0\n"), 2);
  }
}

static void jobTask(void *) {
  JobKind job;
  for (;;) {
    if (xQueueReceive(jobs, &job, portMAX_DELAY) != pdTRUE) continue;
    if (job == JOB_SNAP) runSnap();
    if (job == JOB_AUDIO) runAudio();
    if (job == JOB_YELL) runYell();
    jobRunning = false;
  }
}

static bool startJob(JobKind job) {
  if (jobRunning) return false;
  jobRunning = true;
  xQueueSend(jobs, &job, 0);
  return true;
}

// ---------- The R36S's own mic ----------

static void micTask(void *) {
  const size_t maxSamples = SAMPLE_RATE * MIC_SECONDS;
  for (;;) {
    if (!recording || !micOk) {
      delay(5);
      continue;
    }
    size_t want = min(size_t(1024), maxSamples - micSamples);
    if (want == 0) {
      delay(5);
      continue;
    }
    size_t got = mic.readBytes(reinterpret_cast<char *>(micBuffer + micSamples), want * 2) / 2;
    micSamples = micSamples + got;
  }
}

// ---------- The paddle ----------

// Each packet carries its own ADPCM starting point, so a lost packet is only a short gap.
static const int16_t ADPCM_STEPS[89] = {
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,    23,    25,    28,
    31,    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,    88,    97,    107,   118,
    130,   143,   157,   173,   190,   209,   230,   253,   279,   307,   337,   371,   408,   449,   494,
    544,   598,   658,   724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,
    2272,  2499,  2749,  3024,  3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845,  8630,
    9493,  10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767};
static const int8_t ADPCM_INDEX[16] = {-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};

static void addYellAudio(const uint8_t *packet, size_t length) {
  if (length < 6) return;
  const size_t maxSamples = SAMPLE_RATE * YELL_SECONDS;
  uint16_t seq = packet[1] | (packet[2] << 8);
  int predicted = int16_t(packet[3] | (packet[4] << 8));
  int index = constrain(packet[5], 0, 88);
  const size_t perPacket = (length - 6) * 2;
  // Fills lost packets with silence, so the words stay in the right places.
  while (seq != expectedSeq && yellSamples + perPacket <= maxSamples) {
    memset(yellBuffer + yellSamples, 0, perPacket * 2);
    yellSamples = yellSamples + perPacket;
    expectedSeq++;
  }
  expectedSeq = seq + 1;
  size_t count = yellSamples;
  for (size_t i = 0; i < perPacket && count < maxSamples; i++) {
    int nibble = (packet[6 + i / 2] >> ((i & 1) * 4)) & 0x0F;
    int step = ADPCM_STEPS[index];
    int change = step >> 3;
    if (nibble & 1) change += step >> 2;
    if (nibble & 2) change += step >> 1;
    if (nibble & 4) change += step;
    predicted += (nibble & 8) ? -change : change;
    predicted = constrain(predicted, -32768, 32767);
    index = constrain(index + ADPCM_INDEX[nibble], 0, 88);
    yellBuffer[count++] = predicted;
  }
  yellSamples = count;
}

class PaddleWrites : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    const uint8_t *data = characteristic->getData();
    const size_t length = characteristic->getLength();
    if (length == 0 || !duelOpen) return;
    if (data[0] == 'A') {
      addYellAudio(data, length);
    } else if (data[0] == 'S' && length >= 3) {
      shakeTenths = data[1] | (data[2] << 8);
      shakeChanged = true;
    } else if (data[0] == 'E') {
      paddleEnded = true;
    }
  }
};

class PaddleLink : public BLEServerCallbacks {
  void onConnect(BLEServer *) override {
    paddleConnected = true;
    paddleChanged = true;
  }
  void onDisconnect(BLEServer *) override {
    paddleConnected = false;
    paddleChanged = true;
    BLEDevice::startAdvertising();
  }
};

static void startPaddleLink() {
  BLEDevice::init("GB-Bridge");
  BLEDevice::setMTU(247);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new PaddleLink());
  BLEService *service = server->createService(PADDLE_SERVICE);
  BLECharacteristic *fromPaddle = service->createCharacteristic(PADDLE_TO_BRIDGE, BLECharacteristic::PROPERTY_WRITE_NR);
  fromPaddle->setCallbacks(new PaddleWrites());
  toPaddle = service->createCharacteristic(BRIDGE_TO_PADDLE, BLECharacteristic::PROPERTY_NOTIFY);
  toPaddle->addDescriptor(new BLE2902());
  service->start();
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(PADDLE_SERVICE);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
}

static void tellPaddle(const uint8_t *data, size_t length) {
  if (!paddleConnected) return;
  toPaddle->setValue(const_cast<uint8_t *>(data), length);
  toPaddle->notify();
}

// Payload: the window in ms, then each move name on its own line.
static void startDuel(const char *payload) {
  if (!paddleConnected || !yellBuffer) {
    sendFrame(MSG_YELL, reinterpret_cast<const uint8_t *>("0\n"), 2);
    return;
  }
  String text(payload);
  int firstLine = text.indexOf('\n');
  uint32_t windowMs = constrain(text.substring(0, firstLine < 0 ? text.length() : firstLine).toInt(), 500, 10000);
  duelMoves = firstLine < 0 ? "" : text.substring(firstLine + 1);
  duelMoves.replace('\n', '|');
  yellSamples = 0;
  expectedSeq = 0;
  shakeTenths = 0;
  paddleEnded = false;
  duelEndsAt = millis() + windowMs;
  duelOpen = true;
  const uint8_t go[3] = {'G', uint8_t(windowMs), uint8_t(windowMs >> 8)};
  tellPaddle(go, sizeof(go));
}

static void stopDuel() {
  if (!duelOpen) return;
  duelOpen = false;
  const uint8_t stop = 'X';
  tellPaddle(&stop, 1);
}

static void updateDuel() {
  if (paddleChanged) {
    paddleChanged = false;
    sendPaddle();
  }
  if (shakeChanged) {
    shakeChanged = false;
    const uint16_t tenths = shakeTenths;
    const uint8_t payload[2] = {uint8_t(tenths), uint8_t(tenths >> 8)};
    sendFrame(MSG_SHAKE, payload, sizeof(payload));
  }
  if (!duelOpen) return;
  bool late = int32_t(millis() - duelEndsAt) > int32_t(PADDLE_END_GRACE_MS);
  if (paddleEnded || late || !paddleConnected) {
    duelOpen = false;
    if (!startJob(JOB_YELL)) sendFrame(MSG_YELL, reinterpret_cast<const uint8_t *>("0\n"), 2);
  }
}

// ---------- Commands from the game ----------

static void handleCommand(uint8_t type, const char *payload) {
  switch (type) {
    case CMD_PREVIEW_ON:
      previewOn = cameraOk;
      if (!cameraOk) sendStatus("error: camera not available");
      break;
    case CMD_PREVIEW_OFF:
      previewOn = false;
      break;
    case CMD_SNAP:
      previewOn = false;
      if (!startJob(JOB_SNAP)) sendStatus("server_busy");
      break;
    case CMD_MIC_ON:
      if (!micOk) {
        sendStatus("error: mic not available");
      } else if (jobRunning) {
        sendStatus("server_busy");
      } else {
        previewOn = false;
        micSamples = 0;
        micStartedAt = millis();
        recording = true;
        sendStatus("listening");
      }
      break;
    case CMD_MIC_OFF:
      if (recording) {
        recording = false;
        if (millis() - micStartedAt < MIN_RECORDING_MS) {
          sendStatus("error: recording too short");
        } else if (!startJob(JOB_AUDIO)) {
          sendStatus("server_busy");
        }
      }
      break;
    case CMD_PING: {
      sendFrame(MSG_PONG, nullptr, 0);
      sendStatus(String("camera=") + (cameraOk ? "ok" : "fail") + " mic=" + (micOk ? "ok" : "fail") +
                 " wifi=" + (WiFi.status() == WL_CONNECTED ? "ok" : "down") + " rssi=" + WiFi.RSSI() +
                 " paddle=" + (paddleConnected ? "ok" : "down") + " uptime=" + millis() / 1000 + "s");
      sendPaddle();
      break;
    }
    case CMD_DUEL_START:
      startDuel(payload);
      break;
    case CMD_DUEL_STOP:
      stopDuel();
      break;
    default:
      break;
  }
}

static void readCommands() {
  static uint8_t header[7];
  static size_t headerFill = 0;
  static char payload[MAX_COMMAND + 1];
  static uint32_t payloadLength = 0, payloadFill = 0;
  while (Serial.available()) {
    uint8_t byte = Serial.read();
    if (headerFill < 7) {
      if ((headerFill == 0 && byte != 'G') || (headerFill == 1 && byte != 'B')) {
        headerFill = byte == 'G' ? 1 : 0;
        continue;
      }
      header[headerFill++] = byte;
      if (headerFill < 7) continue;
      memcpy(&payloadLength, header + 3, 4);
      payloadFill = 0;
      if (payloadLength > MAX_COMMAND) {
        headerFill = 0;
        continue;
      }
    } else {
      payload[payloadFill++] = byte;
    }
    if (payloadFill == payloadLength) {
      payload[payloadFill] = 0;
      handleCommand(header[2], payload);
      headerFill = 0;
    }
  }
}

// ---------- Setup ----------

static void onWifi(WiFiEvent_t event) {
  if (event == ARDUINO_EVENT_WIFI_STA_GOT_IP) sendStatus("wifi_ok " + WiFi.localIP().toString());
  if (event == ARDUINO_EVENT_WIFI_STA_DISCONNECTED) sendStatus("wifi_down");
}

void setup() {
  Serial.setRxBufferSize(4096);
  Serial.setTxTimeoutMs(0);
  Serial.begin(115200);
  txLock = xSemaphoreCreateMutex();
  jobs = xQueueCreate(2, sizeof(JobKind));

  micBuffer = static_cast<int16_t *>(ps_malloc(SAMPLE_RATE * MIC_SECONDS * 2));
  yellBuffer = static_cast<int16_t *>(ps_malloc(SAMPLE_RATE * YELL_SECONDS * 2));
  cameraOk = startCamera();
  mic.setPinsPdmRx(42, 41);
  micOk = micBuffer && mic.begin(I2S_MODE_PDM_RX, SAMPLE_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);

  xTaskCreatePinnedToCore(jobTask, "jobs", 12288, nullptr, 2, nullptr, 0);
  xTaskCreatePinnedToCore(micTask, "mic", 4096, nullptr, 3, nullptr, 1);

  startPaddleLink();
  WiFi.onEvent(onWifi);
  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  esp_wifi_set_ps(WIFI_PS_MIN_MODEM);  // Wi-Fi and Bluetooth share one radio, which requires this.
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_NAME, WIFI_PASSWORD);
}

void loop() {
  readCommands();
  updateDuel();
  if (previewOn && !jobRunning) {
    sendPreviewFrame();
  } else {
    delay(2);
  }
}
