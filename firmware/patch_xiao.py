"""Points the XIAO's existing firmware at a new server and Wi-Fi network.

For the original bridge firmware, whose source wasn't available, this edits the compiled
app from a flash backup. firmware/bridge is the source to build from now. The server URL, Wi-Fi name and password each have one pointer in the
code, so new strings go into an unused text area (the WebUSB landing page URL)
and the pointers move to them. The image's checksum and SHA-256 are recomputed.
Without --flash it only writes the patched image, so the result can be checked.

    python3 firmware/patch_xiao.py BACKUP --url http://10.0.0.5:8080 --wifi-file firmware/wifi.txt --out patched.bin
    python3 firmware/patch_xiao.py BACKUP --url ... --wifi-file ... --out patched.bin --flash /dev/cu.usbmodem2101

wifi.txt holds the network name on line 1 and the password on line 2. --flash needs
the XIAO in its bootloader; afterwards, esptool's --after watchdog-reset restarts it.
"""

import argparse
import hashlib
import struct
import subprocess
from pathlib import Path

APP_OFFSET = 0x10000
SECTOR = 0x1000
DROM_VADDR = 0x3C110020
DROM_FILE = 0x20  # Relative to the app image.
SPARE_TEXT = b"https://docs.espressif.com/projects/arduino-esp32/en/latest/_static/webusb.html\0"
# Where the code keeps its pointer to each string, relative to the app image, and where that
# pointer should aim in the expected firmware.
POINTERS = {
    "url": (0x3011C, 0x3C1101CC),
    "ssid": (0x30130, 0x3C11021B),
    "password": (0x3012C, 0x3C11020A),
}
ESPTOOL = Path.home() / "Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"


def segments_end(image):
    offset = 24
    for _ in range(image[1]):
        _, length = struct.unpack_from("<II", image, offset)
        offset += 8 + length
    return offset


def rebuild_checks(image):
    """Recomputes the XOR checksum and SHA-256 that the bootloader verifies."""
    checksum = 0xEF
    offset = 24
    for _ in range(image[1]):
        _, length = struct.unpack_from("<II", image, offset)
        for byte in image[offset + 8:offset + 8 + length]:
            checksum ^= byte
        offset += 8 + length
    checksum_at = (offset + 16) // 16 * 16 - 1
    image[checksum_at] = checksum
    if image[23]:
        image[checksum_at + 1:checksum_at + 33] = hashlib.sha256(image[:checksum_at + 1]).digest()
    return checksum_at + 33 if image[23] else checksum_at + 1


def to_file(vaddr):
    return DROM_FILE + vaddr - DROM_VADDR


def to_vaddr(file_offset):
    return DROM_VADDR + file_offset - DROM_FILE


def patch(image, url, wifi):
    for name, (at, expected) in POINTERS.items():
        target = struct.unpack_from("<I", image, at)[0]
        if target != expected:
            raise SystemExit(f"{name} pointer isn't where it should be: this isn't the expected firmware")
    spare = image.find(SPARE_TEXT)
    new = [(POINTERS["url"][0], url)]
    if wifi:
        new += [(POINTERS["ssid"][0], wifi[0]), (POINTERS["password"][0], wifi[1])]
    needed = sum(len(text) + 1 for _, text in new)
    if spare < 0 or needed > len(SPARE_TEXT):
        raise SystemExit(f"new strings need {needed} bytes, and only {len(SPARE_TEXT)} are spare")
    cursor = spare
    for at, text in new:
        data = text.encode() + b"\0"
        image[cursor:cursor + len(data)] = data
        struct.pack_into("<I", image, at, to_vaddr(cursor))
        cursor += len(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("backup")
    parser.add_argument("--url", required=True)
    parser.add_argument("--wifi-file", help="leave it out to keep the Wi-Fi network already in the firmware")
    parser.add_argument("--out", required=True)
    parser.add_argument("--flash", metavar="PORT")
    args = parser.parse_args()

    wifi = Path(args.wifi_file).read_text().splitlines()[:2] if args.wifi_file else None
    original = Path(args.backup).read_bytes()[APP_OFFSET:]
    image = bytearray(original)
    check = bytearray(original)
    end = rebuild_checks(check)
    if check[:end] != bytearray(original[:end]):
        raise SystemExit("backup fails its own checksum: it isn't a clean copy of the firmware")

    patch(image, args.url, wifi)
    end = rebuild_checks(image)
    Path(args.out).write_bytes(image[:end])

    changed = [at for at in range(0, end, SECTOR) if image[at:at + SECTOR] != bytearray(original[at:at + SECTOR])]
    print(f"patched image: {end} bytes, {len(changed)} sectors differ: {[hex(APP_OFFSET + at) for at in changed]}")
    if not args.flash:
        return
    pairs = []
    for at in changed:
        sector = Path(f"{args.out}.{APP_OFFSET + at:x}")
        sector.write_bytes(image[at:at + SECTOR])
        pairs += [hex(APP_OFFSET + at), str(sector)]
    subprocess.run([ESPTOOL, "--chip", "esp32s3", "--port", args.flash, "--before", "no-reset", "--after", "no-reset",
                    "write-flash", *pairs], check=True)
    for at in changed:
        Path(f"{args.out}.{APP_OFFSET + at:x}").unlink()


if __name__ == "__main__":
    main()
