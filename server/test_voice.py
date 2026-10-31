"""Tests for voice requests. Run with: uv run --with pillow python -m unittest discover -s server"""

import array
import io
import tempfile
import unittest
from pathlib import Path
import wave

from PIL import Image

import creature_store
import test_creatures
import voice


def changes(**values):
    answer = {"say": "Done!", "theme": None, "music": None, "foe_power_change": None, "my_power_change": None,
              "catch_change": None, "foe_level_change": None, "rename_lead": None, "lead_type": None,
              "new_lead_move": None, "move_effect": None, "effects_change": None, "redraw": None, "spawn": None, "undo": False}
    answer.update(values)
    return answer


# Tests must never touch the real creature store.
TEMP_STORE = tempfile.TemporaryDirectory()


def ask(transcript="make it spooky", interpreted=None, **options):
    options.setdefault("key_loader", lambda: "key")
    options.setdefault("log", lambda _: None)
    options.setdefault("store", Path(TEMP_STORE.name))
    return voice.answer(b"wav", transcriber=options.pop("transcriber", lambda *_: transcript),
                        interpreter=options.pop("interpreter", lambda *_: interpreted or changes()), **options)


def split(body):
    head, _, rest = body.partition(b"\n")
    return head.decode(), rest


def recording(samples):
    out = io.BytesIO()
    with wave.open(out, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(16000)
        target.writeframes(array.array("h", samples).tobytes())
    return out.getvalue()


def samples_of(wav):
    with wave.open(io.BytesIO(wav)) as source:
        return array.array("h", source.readframes(source.getnframes()))


class CleanAudio(unittest.TestCase):
    def test_removes_offset_and_boosts_quiet_audio(self):
        cleaned = samples_of(voice.clean_audio(recording([1400 + (500 if i % 2 else -500) for i in range(1000)])))
        self.assertAlmostEqual(sum(cleaned) / len(cleaned), 0, delta=1)
        self.assertEqual(max(cleaned), 6000)  # Limited by MAX_GAIN, 12 x 500.

    def test_loud_audio_is_not_turned_down_or_clipped(self):
        cleaned = samples_of(voice.clean_audio(recording([30000 if i % 2 else -30000 for i in range(1000)])))
        self.assertEqual(max(cleaned), 30000)

    def test_silence_stays_silent(self):
        self.assertEqual(max(samples_of(voice.clean_audio(recording([0] * 100)))), 0)

    def test_other_formats_pass_through(self):
        self.assertEqual(voice.clean_audio(b"not a wav"), b"not a wav")


class Reply(unittest.TestCase):
    def test_first_line_is_the_transcript_then_changes(self):
        heard, level = split(ask(interpreted=changes(theme="spooky", music="slow", say="Boo!")))
        self.assertEqual(heard, "make it spooky")
        self.assertEqual(level, b"say=Boo!\ntheme=spooky\nmusic=slow\n")

    def test_transcript_cannot_add_lines(self):
        heard, _ = split(ask(transcript="one\ntheme=lava\ntwo"))
        self.assertEqual(heard, "one theme=lava two")

    def test_numbers_are_limited_and_zero_is_left_out(self):
        _, level = split(ask(interpreted=changes(foe_power_change=99, my_power_change=-99, catch_change=0)))
        self.assertIn(b"foepower=2\n", level)
        self.assertIn(b"mypower=-2\n", level)
        self.assertNotIn(b"catch=", level)

    def test_unknown_values_are_dropped(self):
        _, level = split(ask(interpreted=changes(theme="hacked", music="loud", lead_type="cosmic",
                                                 new_lead_move={"name": "Bad", "kind": "explode", "type": "aqua"})))
        self.assertEqual(level, b"say=Done!\n")

    def test_text_cannot_add_lines_or_fields(self):
        _, level = split(ask(interpreted=changes(say="hi\ntheme=lava", rename_lead="Max\n|=Power")))
        self.assertNotIn(b"theme=", level)
        self.assertIn(b"leadname=MaxPower\n", level)
        self.assertIn(b"say=hitheme", level)

    def test_lead_changes(self):
        _, level = split(ask(interpreted=changes(rename_lead="Blaze", lead_type="flame",
                                                 new_lead_move={"name": "Scald", "kind": "strike", "type": "aqua"})))
        self.assertEqual(level, b"say=Done!\nleadname=Blaze\nleadtype=flame\nleadmove=Scald|strike|aqua\n")

    def test_new_move_carries_its_look(self):
        _, level = split(ask(interpreted=changes(new_lead_move={
            "name": "Hug", "kind": "strike", "type": "spark", "shape": "heart", "motion": "ring",
            "color1": "#ff0000", "color2": "#ffffff"})))
        self.assertEqual(level, b"say=Done!\nleadmove=Hug|strike|spark\nleadfx=Hug|heart|ring|#ff0000|#ffffff\n")

    def test_move_effect(self):
        effect = {"move_name": "Scald", "shape": "heart", "motion": "rain", "color1": "#ff0000", "color2": "#ffffff"}
        _, level = split(ask(interpreted=changes(move_effect=effect, effects_change=1)))
        self.assertEqual(level, b"say=Done!\neffects=1\nleadfx=Scald|heart|rain|#ff0000|#ffffff\n")

    def test_every_move_can_change(self):
        effect = {"move_name": "*", "shape": "star", "motion": "rain", "color1": "#ff0000", "color2": "#ffffff"}
        _, level = split(ask(interpreted=changes(move_effect=effect)))
        self.assertIn(b"leadfx=*|star|rain|#ff0000|#ffffff\n", level)

    def test_bad_look_is_dropped(self):
        effect = {"move_name": "Scald", "shape": "laser", "motion": "rain", "color1": "red\ntheme=lava", "color2": "#ffffff"}
        _, level = split(ask(interpreted=changes(move_effect=effect, say="Done!")))
        self.assertEqual(level, b"say=I couldn't work out that look. Try describing it differently?\n")

    def test_undo_ignores_other_changes(self):
        _, level = split(ask(interpreted=changes(undo=True, theme="lava", say="Undone")))
        self.assertEqual(level, b"say=Undone\nundo=1\n")


class Store(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Path(self.temp.name)
        creature_store.save("Hoodlum", Image.new("RGBA", (64, 64), (10, 200, 10, 255)), self.store)

    def test_finds_exact_close_and_no_match(self):
        self.assertEqual(creature_store.find("hoodlum", self.store), "Hoodlum")
        self.assertEqual(creature_store.find("Hood Lum", self.store), "Hoodlum")
        self.assertEqual(creature_store.find("Hoodlam", self.store), "Hoodlum")
        self.assertIsNone(creature_store.find("Dragon", self.store))
        self.assertIsNone(creature_store.find("", self.store))

    def test_lists_names(self):
        self.assertEqual(creature_store.names(self.store), ["Hoodlum"])
        self.assertEqual(creature_store.names(self.store / "missing"), [])

    def test_reference_shows_the_sprite_on_magenta(self):
        sprite = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        sprite.paste((10, 200, 10, 255), (20, 20, 44, 44))
        creature_store.save("Mug", sprite, self.store)
        image = Image.open(io.BytesIO(creature_store.reference_image("Mug", self.store)))
        self.assertEqual(image.size, (1024, 1024))
        self.assertEqual(image.getpixel((0, 0)), (255, 0, 255))
        self.assertEqual(image.getpixel((512, 512)), (10, 200, 10))

    def redraw(self, name, full=False, **options):
        return ask(interpreted=changes(redraw={"name": name, "change": "a wizard hat", "full_redesign": full}, say="Sure!"),
                   store=self.store, **options)

    def test_named_creature_edits_its_art_and_updates_the_store(self):
        seen = []

        def editor(reference, change, key, timeout):
            seen.append((reference[:4], change, key))
            return test_creatures.artwork()

        def fail(*_):
            raise AssertionError("drew from scratch")

        _, level = split(self.redraw("hoodlam", editor=editor, drawer=fail))
        self.assertEqual(seen, [(b"\x89PNG", "a wizard hat", "key")])
        self.assertIn(b"redraw=Hoodlum\n", level)
        text, _, sheet = level.partition(b"creature\n")
        self.assertEqual(Image.open(io.BytesIO(sheet)).size, (128, 64))
        self.assertIn(b"say=Sure!", text)
        self.assertGreater(Image.open(self.store / "hoodlum.png").getpixel((32, 32))[1], 100)

    def test_full_redesign_without_a_name_goes_to_the_lead(self):
        def fail(*_):
            raise AssertionError("edited with no reference")

        _, level = split(self.redraw("", full=True, editor=fail, drawer=lambda *_: test_creatures.artwork()))
        self.assertIn(b"redraw=*\n", level)
        self.assertIn(b"creature\n", level)

    def test_small_edit_without_a_name_asks_for_the_name(self):
        def fail(*_):
            raise AssertionError("drew without knowing the creature")

        _, level = split(self.redraw("", editor=fail, drawer=fail))
        self.assertEqual(level, f"say={voice.SAY_ITS_NAME}\n".encode())

    def test_unknown_name_small_edit_asks_for_the_name(self):
        _, level = split(self.redraw("Dragon"))
        self.assertEqual(level, f"say={voice.SAY_ITS_NAME}\n".encode())

    def test_failed_art_keeps_the_old_look_and_says_so(self):
        def fail(*_):
            raise TimeoutError("slow")

        before = (self.store / "hoodlum.png").read_bytes()
        _, level = split(self.redraw("Hoodlum", editor=fail))
        self.assertIn(b"couldn't draw", level)
        self.assertNotIn(b"redraw=", level)
        self.assertEqual((self.store / "hoodlum.png").read_bytes(), before)

    def test_known_names_reach_the_model(self):
        seen = []

        def interpreter(transcript, key, known):
            seen.append(known)
            return changes()

        ask(interpreter=interpreter, store=self.store)
        self.assertEqual(seen, [["Hoodlum"]])


class Spawn(unittest.TestCase):
    def design(self):
        return test_creatures.design(name="Dragon")

    def test_creature_packet_follows_the_changes(self):
        body = ask(interpreted=changes(spawn=self.design(), theme="lava", say="Here it comes!"),
                   drawer=lambda *_: test_creatures.artwork())
        _, level = split(body)
        text, _, packet = level.partition(b"creature\n")
        self.assertEqual(text, b"say=Here it comes!\ntheme=lava\n")
        self.assertTrue(packet.startswith(b"\x89PNG"))
        self.assertIn(b"name=Dragon", packet)

    def test_failed_art_keeps_other_changes_and_says_so(self):
        def fail(*_):
            raise TimeoutError("slow")

        _, level = split(ask(interpreted=changes(spawn=self.design(), theme="lava"), drawer=fail))
        self.assertNotIn(b"creature\n", level)
        self.assertIn(b"theme=lava\n", level)
        self.assertIn(b"couldn't draw", level)

    def test_no_time_left_skips_the_art(self):
        def fail(*_):
            raise AssertionError("tried to draw with no time left")

        logged = []
        packet = voice.spawn_packet(self.design(), "key", 3, fail, logged.append, Path(TEMP_STORE.name))
        self.assertIsNone(packet)
        self.assertIn("no time", logged[0])

    def test_art_gets_only_the_time_left(self):
        seen = []

        def drawer(_, __, timeout):
            seen.append(timeout)
            return test_creatures.artwork()

        voice.spawn_packet(self.design(), "key", 20, drawer, print, Path(TEMP_STORE.name))
        self.assertEqual(seen, [20])


class Failures(unittest.TestCase):
    def fail_with(self, *_):
        raise TimeoutError("slow")

    def test_no_key(self):
        heard, level = split(voice.answer(b"wav", key_loader=lambda: None))
        self.assertEqual(heard, voice.NOTHING_HEARD)
        self.assertIn(b"OpenAI key", level)

    def test_transcription_failure(self):
        heard, level = split(ask(transcriber=self.fail_with))
        self.assertEqual(heard, voice.NOTHING_HEARD)
        self.assertIn(b"couldn't hear", level)

    def test_silence(self):
        heard, level = split(ask(transcript="   "))
        self.assertEqual(heard, voice.NOTHING_HEARD)
        self.assertIn(b"didn't catch", level)

    def test_understanding_failure_keeps_the_transcript(self):
        heard, level = split(ask(interpreter=self.fail_with))
        self.assertEqual(heard, "make it spooky")
        self.assertIn(b"say=", level)


if __name__ == "__main__":
    unittest.main()
