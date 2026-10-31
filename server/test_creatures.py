"""Tests for creature generation. Run with: uv run --with pillow python -m unittest discover -s server"""

import io
import unittest

from PIL import Image

import creatures


def jpeg(color=(200, 40, 30)):
    out = io.BytesIO()
    Image.new("RGB", (640, 480), color).save(out, "JPEG")
    return out.getvalue()


def artwork(background=(255, 0, 255)):
    """A green square on the artist's background."""
    image = Image.new("RGB", (1024, 1024), background)
    image.paste((40, 180, 50), (256, 256, 768, 768))
    out = io.BytesIO()
    image.save(out, "PNG")
    return out.getvalue()


def design(**changes):
    answer = {
        "name": "Mugmon", "type": "flame", "blurb": "Runs on coffee.", "look": "A chubby red mug.",
        "hp": 3, "attack": 4, "defense": 2, "speed": 3,
        "moves": [{"name": "Scald", "kind": "strike", "type": "flame"}, {"name": "Steam", "kind": "hex", "type": "aqua"}],
    }
    answer.update(changes)
    return answer


def parse(packet):
    end = packet.index(b"IEND\xaeB`\x82") + 8
    fields = {}
    for line in packet[end:].decode().splitlines():
        key, value = line.split("=", 1)
        fields.setdefault(key, []).append(value)
    return packet[:end], fields


def make(designer=lambda *_: design(), drawer=lambda *_: artwork(), key="key", log=print):
    return creatures.make_creature(jpeg(), design=designer, draw=drawer, key_loader=lambda: key, log=log)


class PhotoCreature(unittest.TestCase):
    def test_same_photo_gives_the_same_creature(self):
        photo = jpeg()
        self.assertEqual(creatures.photo_creature(photo).name, creatures.photo_creature(photo).name)

    def test_color_picks_the_type(self):
        self.assertEqual(creatures.photo_creature(jpeg((220, 30, 20))).type, "flame")
        self.assertEqual(creatures.photo_creature(jpeg((30, 80, 220))).type, "aqua")
        self.assertEqual(creatures.photo_creature(jpeg((40, 180, 50))).type, "leaf")
        self.assertEqual(creatures.photo_creature(jpeg((128, 128, 128))).type, "stone")

    def test_stats_are_ranks_and_moves_are_valid(self):
        made = creatures.photo_creature(jpeg())
        for stat in (made.hp, made.attack, made.defense, made.speed):
            self.assertIn(stat, range(1, 6))
        self.assertEqual(len(made.moves), 4)
        for _, kind, type_name in made.moves:
            self.assertIn(kind, creatures.KINDS)
            self.assertIn(type_name, creatures.TYPES)

    def test_sprite_corners_are_transparent(self):
        sprite = creatures.photo_creature(jpeg()).sprite
        self.assertEqual(sprite.getpixel((0, 0))[3], 0)
        self.assertEqual(sprite.getpixel((16, 16))[3], 255)

    def test_rotation_turns_the_photo_upright(self):
        out = io.BytesIO()
        image = Image.new("RGB", (640, 480), (0, 0, 0))
        image.paste((255, 255, 255), (0, 0, 640, 240))
        image.save(out, "JPEG")
        upright = creatures.open_photo(out.getvalue())
        self.assertLess(upright.getpixel((320, 50))[0], 50)
        self.assertGreater(upright.getpixel((320, 430))[0], 200)


class AiCreature(unittest.TestCase):
    def test_uses_both_models_when_a_key_exists(self):
        looks = []

        def drawer(_, look, key):
            looks.append((look, key))
            return artwork()

        made = make(drawer=drawer)
        self.assertEqual((made.name, made.source), ("Mugmon", "ai"))
        self.assertEqual(looks, [("A chubby red mug.", "key")])

    def test_magenta_background_is_removed(self):
        sprite = make().sprite
        self.assertEqual(sprite.size, (64, 64))
        self.assertEqual(sprite.getpixel((2, 2))[3], 0)
        pixel = sprite.getpixel((32, 32))
        self.assertEqual(pixel[3], 255)
        self.assertGreater(pixel[1], pixel[0])

    def test_no_key_uses_the_photo_and_never_asks(self):
        def fail(*_):
            raise AssertionError("asked without a key")

        made = make(designer=fail, drawer=fail, key=None)
        self.assertEqual(made.source, "photo")

    def test_design_failure_falls_back_and_logs(self):
        def fail(*_):
            raise TimeoutError("slow")

        logged = []
        made = make(designer=fail, log=logged.append)
        self.assertEqual(made.source, "photo")
        self.assertIn("slow", logged[0])

    def test_art_failure_keeps_the_design_with_a_photo_sprite(self):
        def fail(*_):
            raise TimeoutError("slow")

        logged = []
        made = make(drawer=fail, log=logged.append)
        self.assertEqual(made.name, "Mugmon")
        self.assertEqual(made.sprite.size, (32, 32))
        self.assertIn("slow", logged[0])

    def test_art_without_the_magenta_background_uses_the_photo_sprite(self):
        logged = []
        made = make(drawer=lambda *_: artwork(background=(250, 250, 250)), log=logged.append)
        self.assertEqual(made.sprite.size, (32, 32))
        self.assertIn("background", logged[0])

    def test_numbers_and_text_are_limited(self):
        made = make(designer=lambda *_: design(
            name="Mug|mon=\n<script>VeryVeryVeryLong", hp=500, attack=-3, type="cosmic", blurb="line\nbreak=|"))
        self.assertNotRegex(made.name, r"[|=\n<>]")
        self.assertLessEqual(len(made.name), 12)
        self.assertNotRegex(made.blurb, r"[|=\n]")
        self.assertEqual((made.hp, made.attack, made.type), (5, 1, "stone"))

    def test_moves_keep_valid_looks_only(self):
        good = {"name": "Scald", "kind": "strike", "type": "flame", "shape": "flame", "motion": "beam",
                "color1": "#ff0000", "color2": "#ffee00"}
        bad = {"name": "Steam", "kind": "hex", "type": "aqua", "shape": "laser", "motion": "beam",
               "color1": "#ff0000", "color2": "#ffee00"}
        badColor = dict(good, name="Zap", color1="red\nhp=99")
        made = make(designer=lambda *_: design(moves=[good, bad, badColor]))
        _, fields = parse(creatures.encode(made))
        self.assertEqual(fields["fx"], ["1|flame|beam|#ff0000|#ffee00"])

    def test_a_creature_can_always_do_damage(self):
        made = make(designer=lambda *_: design(moves=[{"name": "Stare", "kind": "hex", "type": "aqua"}]))
        self.assertTrue(any(kind in creatures.DAMAGING for _, kind, _ in made.moves))


class Packet(unittest.TestCase):
    def test_packet_is_a_sheet_then_details(self):
        png, fields = parse(creatures.encode(creatures.photo_creature(jpeg())))
        sheet = Image.open(io.BytesIO(png))
        self.assertEqual(sheet.size, (128, 64))
        self.assertEqual(fields["type"], ["flame"])
        self.assertEqual(len(fields["move"]), 4)

    def test_ai_packet_is_small_enough_for_the_link(self):
        self.assertLess(len(creatures.encode(make())), 12000)


if __name__ == "__main__":
    unittest.main()
