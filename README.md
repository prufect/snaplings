# Magic Game Boy: Snaplings

Photograph anything, battle it, catch it and build a team. The game runs on an R36S with ArkOS, a XIAO ESP32S3 Sense on its OTG port handles the camera and Wi-Fi, and a server on your Mac turns each photo into a creature using OpenAI.

## Play

1. Turn on your phone's hotspot, and connect your Mac to it. The XIAO is set up to join the same hotspot.
2. Start the server, which needs `OPENAI_API_KEY=...` in `server/.env`:

   ```bash
   uv run server/server.py
   ```

3. On the R36S, open Ports → Snaplings.

Without a key or a connection to OpenAI, the server still makes a creature from the photo itself. Battles and your team don't need the server at all.

**Controls:** A confirms and snaps, B goes back, the D-pad or left stick moves, R1/R2 change the volume, and holding Start + Select quits.

**Talking:** hold L1, speak, and let go. You can change the world's look and the music, make battles or catching easier or harder, rename your lead creature or teach it a move, restyle its moves' effects ("make my attacks rain pink hearts"), change how many particles appear ("bigger explosions"), redraw a creature ("give Plaidgo a wizard hat" or "make my creature a robot knight"), ask for a creature ("I want to fight a giant angry pizza"), or say "undo that." Changes are saved on the card. To edit a creature's current art, say its name so the server knows which one you mean.

## How it fits together

- `game/snaplings/`: the LÖVE 11.4 game. Battle rules are in `battle.lua`, and the screens are in `main.lua`.
- `game/Snaplings.sh`: the ArkOS launcher. It keeps opening up `/dev/ttyACM0` whenever the XIAO reconnects.
- `server/server.py`: answers the XIAO's `POST /photo` and `POST /audio`. Uploads are saved to `server/data/`.
- `server/creatures.py`: `gpt-5.4-mini` designs each creature from the photo, and `gpt-image-2.5-flare` draws it. A packet is a 128x64 PNG (front, then back) followed by `key=value` lines. Code applies all the limits, and the game owns every battle number.
- `server/voice.py`: `gpt-transcribe` hears the recording, `gpt-5.4-mini` maps it onto a closed list of changes, and the reply goes to the game as the XIAO's level message. `game/snaplings/rules.lua` applies those changes and keeps the undo history.
- `game/snaplings/fx.lua`: move effects, drawn from shapes. Each move's look is a shape, a motion and two colors, chosen by the AI when a creature is made, with defaults by type.
- `server/creature_store.py`: keeps each creature's art by name in `server/data/creatures/`, because the XIAO can't send the game's sprites. `server/import_creatures.py` copies in creatures saved on the card.
- `firmware/bridge/`: the XIAO ESP32S3 Sense firmware (camera, mic, Wi-Fi and the link to the game). Build it with `firmware/build_bridge.sh`.
- `firmware/paddle/`: the XIAO nRF54L15 Sense paddle firmware. Build it with `firmware/build_paddle.sh`.
- `firmware/set_wifi.sh`: saves your Wi-Fi details to `firmware/wifi.txt`, which git ignores.
- `firmware/patch_xiao.py`: re-points the original compiled bridge firmware at a new server address or Wi-Fi network, using a flash backup of your own.

## Common jobs

If your Mac's address changes, rebuild the bridge firmware with the new address and flash it. Give it the XIAO's USB port:

```bash
firmware/build_bridge.sh http://NEW_ADDRESS:8080 /dev/cu.usbmodemXXXX
```

To change the camera's rotation, set both `CAMERA_TURNS` in `game/snaplings/main.lua` and `CAMERA_QUARTER_TURNS` in `server/creatures.py`.

## Tests

```bash
luajit game/tests/test_battle.lua
```

```bash
luajit game/tests/test_rules.lua
```

```bash
luajit game/tests/test_fx.lua
```

```bash
uv run --with pillow python -m unittest discover -s server
```

`game/tests/run_game_test.sh PACKET PHOTO SPAWN OUTPUT_DIR` plays every screen by script on LÖVE 11.4 in a Linux container and saves screenshots.
