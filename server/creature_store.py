"""Remembers each creature's art by name, so a voice request can edit the art it already has.

The XIAO can only send photos and recordings, so the game can't tell the server what a
creature looks like. The server keeps its own copy of everything it makes instead.
"""

import difflib
import io
import re
from pathlib import Path

from PIL import Image

STORE = Path(__file__).parent / "data" / "creatures"
MATCH_CUTOFF = 0.75  # Speech often mangles made-up names, so close spellings count.


def _key(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def save(name, sprite, store=STORE):
    if not _key(name):
        return
    store.mkdir(parents=True, exist_ok=True)
    sprite.save(store / f"{_key(name)}.png", "PNG")
    (store / f"{_key(name)}.txt").write_text(name)


def names(store=STORE):
    return sorted(path.read_text() for path in store.glob("*.txt")) if store.exists() else []


def find(spoken, store=STORE):
    """The stored name closest to what was said, or None."""
    known = {_key(name): name for name in names(store)}
    spoken_key = _key(spoken or "")
    if not spoken_key or not known:
        return None
    if spoken_key in known:
        return known[spoken_key]
    close = difflib.get_close_matches(spoken_key, known, n=1, cutoff=MATCH_CUTOFF)
    return known[close[0]] if close else None


def reference_image(name, store=STORE):
    """The creature's art, enlarged on a magenta background, as PNG bytes for the image model."""
    sprite = Image.open(store / f"{_key(name)}.png").convert("RGBA")
    background = Image.new("RGBA", sprite.size, (255, 0, 255, 255))
    background.alpha_composite(sprite)
    out = io.BytesIO()
    background.convert("RGB").resize((1024, 1024), Image.Resampling.NEAREST).save(out, "PNG")
    return out.getvalue()
