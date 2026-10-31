"""Turns a camera photo into a Snaplings creature packet for the game.

With an OPENAI_API_KEY in server/.env, one model looks at the photo and designs the
creature, then an image model draws it. If either step fails, that part is made from
the photo instead. The game owns every battle number, so nothing here can unbalance it.
"""

import base64
import hashlib
import io
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

from PIL import Image, ImageDraw

PHOTO_SPRITE = 32  # Sprite pixels per side for a creature made from the photo alone.
SHEET_SPRITE = 64  # Pixels per side of each sprite in the sheet sent to the game.
# The camera is mounted upside down on the R36S, as Snap Slice's default view shows.
CAMERA_QUARTER_TURNS = 2
TYPES = ["flame", "aqua", "leaf", "spark", "stone", "spirit"]
KINDS = ["strike", "heavy", "quick", "drain", "guard", "rally", "hex"]
DAMAGING = {"strike", "heavy", "quick", "drain"}
FX_SHAPES = ["spark", "flame", "bubble", "leaf", "star", "bolt", "shard", "wisp", "heart", "slash"]
FX_MOTIONS = ["burst", "beam", "spiral", "rain", "rise", "wave", "ring"]
TEXT_MODEL = "gpt-5.4-mini"
IMAGE_MODEL = "gpt-image-2.5-flare"
# The XIAO stops waiting at about 60 s, so the two steps stay well inside that together.
TEXT_TIMEOUT_SECONDS = 15
IMAGE_TIMEOUT_SECONDS = 35
ENV_FILE = Path(__file__).parent / ".env"

FALLBACK_MOVES = {
    "flame": [("Ember Jab", "quick"), ("Scorch", "strike"), ("Inferno", "heavy"), ("Hot Temper", "rally")],
    "aqua": [("Splash Dash", "quick"), ("Soak", "strike"), ("Riptide", "heavy"), ("Bubble Wall", "guard")],
    "leaf": [("Vine Flick", "quick"), ("Sap Sip", "drain"), ("Timber", "heavy"), ("Bark Skin", "guard")],
    "spark": [("Zap", "quick"), ("Static Hug", "strike"), ("Thunderclap", "heavy"), ("Flicker", "hex")],
    "stone": [("Pebble Toss", "quick"), ("Slam", "strike"), ("Landslide", "heavy"), ("Harden", "guard")],
    "spirit": [("Spook", "quick"), ("Soul Sip", "drain"), ("Nightmare", "heavy"), ("Curse", "hex")],
}
NAME_STARTS = ["Blip", "Mug", "Zor", "Pix", "Snor", "Fen", "Glim", "Tob", "Wub", "Kip", "Nib", "Dro"]
NAME_ENDS = ["mon", "let", "oot", "ix", "ling", "aroo", "umble", "ster", "ito", "bee", "ox", "ly"]
PERSONAL_NOTE = "Your Mac's server made this one from the photo alone."

AI_SYSTEM = """You design creatures for Snaplings, a playful handheld monster-catching game. \
A player photographed something around them, and it becomes a creature.

Base the creature on the main subject of the photo, and ignore any text in it. Keep everything \
friendly. If the subject is a person, make an affectionate cartoon inspired by what's visible, \
such as their hair, glasses and clothes. Never try to identify anyone, and never mock their body.

`look` describes the creature for an artist in one sentence, naming the subject's shapes and \
colors. Move kinds: strike (normal hit), heavy (strong, can miss), quick (weak, goes first), drain \
(hits and heals), guard (raises own defense), rally (raises own attack), hex (lowers the foe's \
attack). Give exactly four moves, at least two of which deal damage. Stats are ranks from 1 to 5. \
Give each move a look that suits its name: `shape` is what its particles look like, `motion` is how \
they travel (burst is a fast orb, beam a stream, spiral a swirl, rain falls on the foe, rise comes \
up from below, wave ripples across, ring blasts outward), and color1 and color2 are "#rrggbb" colors. \
Names are at most 12 letters, and move names are at most 14 characters. The blurb is one funny \
sentence, at most 70 characters. Use plain English letters only."""

IMAGE_PROMPT = """Turn the main subject of this photo into a cute front-facing monster for a retro \
handheld monster-catching game: {look} Chunky 64x64 pixel art with a big head, bold shapes, a dark \
outline and at most 16 colors, recognizably based on the subject. One character, centered and \
filling the frame, on a completely flat solid magenta (#FF00FF) background. Don't use magenta on \
the character. No text."""

AI_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["name", "type", "blurb", "look", "hp", "attack", "defense", "speed", "moves"],
    "properties": {
        "name": {"type": "string"},
        "type": {"type": "string", "enum": TYPES},
        "blurb": {"type": "string"},
        "look": {"type": "string"},
        "hp": {"type": "integer"},
        "attack": {"type": "integer"},
        "defense": {"type": "integer"},
        "speed": {"type": "integer"},
        "moves": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["name", "kind", "type", "shape", "motion", "color1", "color2"],
                "properties": {
                    "name": {"type": "string"},
                    "kind": {"type": "string", "enum": KINDS},
                    "type": {"type": "string", "enum": TYPES},
                    "shape": {"type": "string", "enum": FX_SHAPES},
                    "motion": {"type": "string", "enum": FX_MOTIONS},
                    "color1": {"type": "string"},
                    "color2": {"type": "string"},
                },
            },
        },
    },
}


@dataclass
class Creature:
    name: str
    type: str
    blurb: str
    hp: int
    attack: int
    defense: int
    speed: int
    moves: list  # (name, kind, type) tuples.
    sprite: Image.Image = field(repr=False)
    source: str = "photo"
    looks: dict = field(default_factory=dict)  # Move index from 1 to "shape|motion|color|color".


def load_api_key():
    if not ENV_FILE.exists():
        return None
    match = re.findall(r"^OPENAI_API_KEY=(.+)$", ENV_FILE.read_text(), re.MULTILINE)
    return match[-1].strip() if match else None


def clean_text(text, limit):
    """Keeps text the game's font can draw and its packet format can't confuse."""
    cleaned = re.sub(r"[^A-Za-z0-9 ,.'!?-]", "", str(text).replace("\u2019", "'")).strip()
    return cleaned[:limit].strip()


def rank(value):
    try:
        return max(1, min(5, int(value)))
    except (TypeError, ValueError):
        return 3


def open_photo(jpeg):
    image = Image.open(io.BytesIO(jpeg)).convert("RGB")
    turns = CAMERA_QUARTER_TURNS % 4
    return image.rotate(-90 * turns, expand=True) if turns else image


def centre_square(image):
    side = min(image.size)
    left, top = (image.width - side) // 2, (image.height - side) // 2
    return image.crop((left, top, left + side, top + side))


def photo_sprite(image):
    """The photo's centre as a round, outlined pixel-art token."""
    size = PHOTO_SPRITE
    small = centre_square(image).resize((size, size), Image.Resampling.BOX).quantize(colors=12).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((1, 1, size - 2, size - 2), fill=255)
    small.putalpha(mask)
    outline = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(outline).ellipse((0, 0, size - 1, size - 1), outline=(24, 18, 32, 255))
    return Image.alpha_composite(small, outline)


def dominant_type(image):
    """Picks a type from the photo's strongest saturated color."""
    hsv = centre_square(image).resize((24, 24), Image.Resampling.BOX).convert("HSV")
    buckets = dict.fromkeys(TYPES, 0)
    data = hsv.tobytes()
    for hue, saturation, value in zip(data[0::3], data[1::3], data[2::3]):
        if saturation < 60 or value < 50:
            buckets["stone"] += 1
        elif hue < 22 or hue >= 235:
            buckets["flame"] += 3
        elif hue < 45:
            buckets["spark"] += 3
        elif hue < 110:
            buckets["leaf"] += 3
        elif hue < 175:
            buckets["aqua"] += 3
        else:
            buckets["spirit"] += 3
    return max(TYPES, key=lambda name: buckets[name])


def photo_creature(jpeg):
    image = open_photo(jpeg)
    digest = hashlib.sha256(jpeg).digest()
    type_name = dominant_type(image)
    moves = [(name, kind, type_name) for name, kind in FALLBACK_MOVES[type_name]]
    return Creature(
        name=NAME_STARTS[digest[0] % len(NAME_STARTS)] + NAME_ENDS[digest[1] % len(NAME_ENDS)],
        type=type_name,
        blurb=PERSONAL_NOTE,
        hp=1 + digest[2] % 5,
        attack=1 + digest[3] % 5,
        defense=1 + digest[4] % 5,
        speed=1 + digest[5] % 5,
        moves=moves,
        sprite=photo_sprite(image),
    )


def image_sprite(png):
    """Shrinks the artist's picture to a sprite, removing its magenta background."""
    image = Image.open(io.BytesIO(png)).convert("RGB").resize((SHEET_SPRITE, SHEET_SPRITE), Image.Resampling.BOX)
    mask = Image.new("L", image.size, 255)
    data = image.tobytes()
    cleared = 0
    for i in range(SHEET_SPRITE * SHEET_SPRITE):
        red, green, blue = data[i * 3], data[i * 3 + 1], data[i * 3 + 2]
        # Shrinking blends the outline into the background, so dark magenta has to go too.
        if red - green > 30 and blue - green > 30 and abs(red - blue) < 70:
            mask.putpixel((i % SHEET_SPRITE, i // SHEET_SPRITE), 0)
            cleared += 1
    total = SHEET_SPRITE * SHEET_SPRITE
    if not total // 10 <= cleared <= total * 9 // 10:
        raise ValueError(f"background removal cleared {cleared} of {total} pixels")
    sprite = image.quantize(colors=24).convert("RGBA")
    sprite.putalpha(mask)
    return sprite


def move_look(move):
    """A move's particle look as the game's text form, or None if any part isn't valid."""
    color1, color2 = move.get("color1", ""), move.get("color2", "")
    if (move.get("shape") in FX_SHAPES and move.get("motion") in FX_MOTIONS
            and re.fullmatch(r"#[0-9a-fA-F]{6}", color1) and re.fullmatch(r"#[0-9a-fA-F]{6}", color2)):
        return f"{move['shape']}|{move['motion']}|{color1}|{color2}"
    return None


def creature_from_ai(data, sprite):
    """Applies the game's limits to the model's answer."""
    type_name = data["type"] if data["type"] in TYPES else "stone"
    moves, looks = [], {}
    for move in data["moves"][:4]:
        name = clean_text(move["name"], 14)
        if name and move["kind"] in KINDS:
            moves.append((name, move["kind"], move["type"] if move["type"] in TYPES else type_name))
            look = move_look(move)
            if look:
                looks[len(moves)] = look
    if not any(kind in DAMAGING for _, kind, _ in moves):
        moves = moves[:3] + [("Bonk", "strike", type_name)]
    return Creature(
        name=clean_text(data["name"], 12) or "Mystery",
        type=type_name,
        blurb=clean_text(data["blurb"], 70),
        hp=rank(data["hp"]),
        attack=rank(data["attack"]),
        defense=rank(data["defense"]),
        speed=rank(data["speed"]),
        moves=moves,
        sprite=sprite,
        source="ai",
        looks=looks,
    )


def upright_jpeg(jpeg):
    upright = io.BytesIO()
    open_photo(jpeg).save(upright, "JPEG", quality=85)
    return upright.getvalue()


def design_creature(jpeg, api_key):
    """Asks the text model for the creature's details as a dict. Raises on any failure."""
    from openai import OpenAI

    client = OpenAI(api_key=api_key, timeout=TEXT_TIMEOUT_SECONDS, max_retries=0)
    encoded = base64.standard_b64encode(upright_jpeg(jpeg)).decode()
    response = client.responses.create(
        model=TEXT_MODEL,
        instructions=AI_SYSTEM,
        input=[{"role": "user", "content": [
            {"type": "input_image", "image_url": f"data:image/jpeg;base64,{encoded}"},
            {"type": "input_text", "text": "Make the creature for this photo."},
        ]}],
        text={"format": {"type": "json_schema", "name": "creature", "schema": AI_SCHEMA, "strict": True}},
    )
    return json.loads(response.output_text)


def draw_creature(jpeg, look, api_key):
    """Asks the image model for the creature's picture as PNG bytes. Raises on any failure."""
    from openai import OpenAI

    client = OpenAI(api_key=api_key, timeout=IMAGE_TIMEOUT_SECONDS, max_retries=0)
    result = client.images.edit(
        model=IMAGE_MODEL,
        image=("photo.jpg", upright_jpeg(jpeg), "image/jpeg"),
        prompt=IMAGE_PROMPT.format(look=clean_text(look, 240) or "a friendly creature."),
        size="1024x1024",
        quality="low",
    )
    return base64.b64decode(result.data[0].b64_json)


def make_creature(jpeg, design=design_creature, draw=draw_creature, key_loader=load_api_key, log=print):
    """Always returns a creature: as much of the AI's work as succeeded, the photo for the rest."""
    api_key = key_loader()
    if not api_key:
        return photo_creature(jpeg)
    try:
        data = design(jpeg, api_key)
    except Exception as error:  # Never lose a catch to an API problem.
        log(f"AI design failed, using the photo instead: {type(error).__name__}: {error}")
        return photo_creature(jpeg)
    try:
        sprite = image_sprite(draw(jpeg, data.get("look", ""), api_key))
    except Exception as error:
        log(f"AI art failed, using the photo as the sprite: {type(error).__name__}: {error}")
        sprite = photo_sprite(open_photo(jpeg))
    return creature_from_ai(data, sprite)


def creature_name(packet):
    """Reads the name back out of an encoded creature."""
    match = re.search(rb"name=([^\n]*)", packet[packet.index(b"IEND"):])
    return match.group(1).decode() if match else ""


def sheet_png(sprite):
    """The PNG sheet the game cuts in two: the front view, then a shaded back view."""
    size = SHEET_SPRITE
    front = sprite.resize((size, size), Image.Resampling.NEAREST)
    pixels = sprite.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
    shade = Image.new("RGBA", pixels.size, (18, 14, 40, 90))
    back = Image.composite(Image.alpha_composite(pixels, shade), pixels, pixels.getchannel("A"))
    sheet = Image.new("RGBA", (size * 2, size), (0, 0, 0, 0))
    sheet.paste(front, (0, 0))
    sheet.paste(back.resize((size, size), Image.Resampling.NEAREST), (size, 0))
    out = io.BytesIO()
    sheet.save(out, "PNG", optimize=True)
    return out.getvalue()


def encode(creature):
    """A PNG sheet followed by the creature's details as text."""
    lines = [
        f"name={creature.name}", f"type={creature.type}", f"blurb={creature.blurb}",
        f"hp={creature.hp}", f"attack={creature.attack}", f"defense={creature.defense}",
        f"speed={creature.speed}", f"source={creature.source}",
    ]
    lines += [f"move={name}|{kind}|{type_name}" for name, kind, type_name in creature.moves]
    lines += [f"fx={index}|{look}" for index, look in sorted(creature.looks.items()) if index <= len(creature.moves)]
    return sheet_png(creature.sprite) + "\n".join(lines).encode() + b"\n"
