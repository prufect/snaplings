# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "openai"]
# ///
"""Local server for the Magic Game Boy's XIAO.

The XIAO posts a JPEG to /photo and a WAV to /audio. Every upload is saved to
server/data/ and logged. /photo answers with a Snaplings creature (creatures.py),
and /audio answers with what the player said and the changes it asks for (voice.py).

Run it with: uv run server/server.py
"""

import sys
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import creature_store
import creatures
import voice
import yell

PORT = 8080
DATA = Path(__file__).parent / "data"


def log(message):
    print(f"{datetime.now():%H:%M:%S} {message}", flush=True)


def save(body, extension):
    DATA.mkdir(exist_ok=True)
    path = DATA / f"{datetime.now():%Y%m%d-%H%M%S-%f}{extension}"
    path.write_bytes(body)
    return path


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        uploads = sorted(path.name for path in DATA.glob("*")) if DATA.exists() else []
        lines = ["Magic Game Boy server", f"{len(uploads)} uploads", *uploads[-10:]]
        self.reply(200, "\n".join(lines).encode(), "text/plain")

    def do_POST(self):
        started = time.monotonic()
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            if self.path == "/photo":
                saved = save(body, ".jpg")
                creature = creatures.make_creature(body, log=log)
                creature_store.save(creature.name, creature.sprite)
                log(f"made {creature.name}, a {creature.type} creature, from the {creature.source}")
                answer, kind = creatures.encode(creature), "image/png"
            elif self.path == "/audio":
                saved = save(body, ".wav")
                answer, kind = voice.answer(body, log=log), "text/plain"
            elif self.path == "/yell":
                saved = save(body, ".wav")
                answer, kind = yell.answer(body, self.headers.get("X-Moves", ""), log=log), "text/plain"
            else:
                self.reply(404, b"unknown route", "text/plain")
                return
        except Exception as error:  # A bad upload shouldn't take the server down.
            log(f"{self.path}: {len(body)} bytes failed: {error}")
            self.reply(400, str(error).encode(), "text/plain")
            return
        took = time.monotonic() - started
        log(f"{self.path}: {len(body)} bytes saved as {saved.name}, {len(answer)} byte reply in {took:.2f} s")
        self.reply(200, answer, kind)

    def log_message(self, format, *args):
        pass  # do_POST logs what matters.


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else PORT
    log(f"listening on port {port}")
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
