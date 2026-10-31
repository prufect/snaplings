import array
import io
import math
import unittest
import wave

import yell

MOVES = ["Ember Bite", "Tidal Slam", "Quick Jab", "Hexfog"]


def recording(amplitude, seconds=1.0):
    samples = array.array("h", (int(amplitude * math.sin(i * 0.3)) for i in range(int(16000 * seconds))))
    out = io.BytesIO()
    with wave.open(out, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(16000)
        target.writeframes(samples.tobytes())
    return out.getvalue()


class MatchMove(unittest.TestCase):
    def test_exact_name(self):
        self.assertEqual(yell.match_move("Tidal Slam!", MOVES), 2)

    def test_misheard_name(self):
        self.assertEqual(yell.match_move("hex fog", MOVES), 4)
        self.assertEqual(yell.match_move("tidle slam", MOVES), 2)

    def test_one_word_of_a_longer_name(self):
        self.assertEqual(yell.match_move("EMBER!", MOVES), 1)

    def test_last_move_yelled_wins(self):
        self.assertEqual(yell.match_move("ember bite no wait quick jab", MOVES), 3)

    def test_nothing_close(self):
        self.assertEqual(yell.match_move("what are we having for dinner", MOVES), 0)
        self.assertEqual(yell.match_move("", MOVES), 0)


class Answer(unittest.TestCase):
    def reply(self, wav, said="tidal slam", **kwargs):
        return yell.answer(wav, "|".join(MOVES), transcriber=lambda *_: said, key_loader=lambda: "key", log=lambda _: None, **kwargs)

    def test_loud_yell_returns_move_and_words(self):
        self.assertEqual(self.reply(recording(8000)), "2\ntidal slam")

    def test_quiet_recording_never_reaches_the_transcriber(self):
        def fail(*_):
            raise AssertionError("shouldn't transcribe")

        self.assertEqual(yell.answer(recording(100), "|".join(MOVES), transcriber=fail, key_loader=lambda: "key", log=lambda _: None), "0\n")

    def test_short_loud_yell_in_a_long_window_counts(self):
        quiet, loud = recording(50, 4), recording(8000, 0.3)
        with wave.open(io.BytesIO(quiet)) as q, wave.open(io.BytesIO(loud)) as l:
            frames = q.readframes(q.getnframes()) + l.readframes(l.getnframes())
        out = io.BytesIO()
        with wave.open(out, "wb") as target:
            target.setnchannels(1)
            target.setsampwidth(2)
            target.setframerate(16000)
            target.writeframes(frames)
        self.assertEqual(self.reply(out.getvalue()), "2\ntidal slam")

    def test_transcription_failure_still_answers(self):
        def fail(*_):
            raise RuntimeError("down")

        self.assertEqual(yell.answer(recording(8000), "|".join(MOVES), transcriber=fail, key_loader=lambda: "key", log=lambda _: None), "0\n")

    def test_no_key_still_answers(self):
        self.assertEqual(yell.answer(recording(8000), "|".join(MOVES), key_loader=lambda: None, log=lambda _: None), "0\n")


if __name__ == "__main__":
    unittest.main()
