# /// script
# dependencies = ["pillow"]
# ///
"""Copies the art of creatures saved from the game to the server, so voice can edit them.

    uv run server/import_creatures.py ~/Backups/snaplings/creatures
"""

import io
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
import creature_store

PNG_END = b"IEND\xaeB`\x82"


def main():
    for path in sorted(Path(sys.argv[1]).glob("*.mon")):
        packet = path.read_bytes()
        end = packet.index(PNG_END) + len(PNG_END)
        fields = dict(line.split("=", 1) for line in packet[end:].decode().splitlines() if "=" in line)
        sheet = Image.open(io.BytesIO(packet[:end])).convert("RGBA")
        size = sheet.height
        creature_store.save(fields["name"], sheet.crop((0, 0, size, size)))
        print(f"copied {fields['name']}")


if __name__ == "__main__":
    main()
