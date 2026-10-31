"""Works out which move the second player yelled into the paddle.

The game sends the wild creature's move names with the recording. The speech is transcribed
and matched against them in code, with no second model call, so the turn waits as little as
possible. The reply is the move's number (0 for none), a newline, then what was heard.
"""

import array
import difflib
import io
import os
import re
import wave

import creatures
import voice

TIMEOUT_SECONDS = 8
MATCH_WHOLE_NAME = 0.72
MATCH_ONE_WORD = 0.85  # One word of a longer name, like "ember" for "Ember Bite", must be closer.
MIN_LEVEL = int(os.environ.get("YELL_MIN_LEVEL", 600))  # Quieter than this isn't a yell.
LEVEL_WINDOW_SAMPLES = 3200  # 200 ms at 16 kHz.


def words_of(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def loudest_level(wav):
    """The RMS of the recording's loudest moment, so one short yell in a quiet window still counts."""
    try:
        with wave.open(io.BytesIO(wav)) as source:
            samples = array.array("h", source.readframes(source.getnframes()))
    except (wave.Error, EOFError):
        return 0
    if not samples:
        return 0
    offset = sum(samples) / len(samples)
    loudest = 0.0
    for start in range(0, max(1, len(samples) - LEVEL_WINDOW_SAMPLES), LEVEL_WINDOW_SAMPLES // 2):
        window = samples[start:start + LEVEL_WINDOW_SAMPLES]
        loudest = max(loudest, sum((s - offset) ** 2 for s in window) / len(window))
    return loudest ** 0.5


def similarity(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio()


def match_move(transcript, moves):
    """Returns the 1-based number of the last move yelled, or 0 if nothing was close."""
    heard = words_of(transcript)
    best_end, best_score, best_move = -1, 0.0, 0
    for number, move in enumerate(moves, 1):
        name = words_of(move)
        if not name:
            continue
        joined = "".join(name)
        for size in range(max(1, len(name) - 1), len(name) + 2):  # Speech may split or join words.
            for start in range(0, len(heard) - size + 1):
                score = similarity("".join(heard[start:start + size]), joined)
                end = start + size
                if score >= MATCH_WHOLE_NAME and (end, score) > (best_end, best_score):
                    best_end, best_score, best_move = end, score, number
        if len(name) > 1:
            for start, word in enumerate(heard):
                for part in name:
                    score = similarity(word, part)
                    if len(part) >= 3 and score >= MATCH_ONE_WORD and (start + 1, score) > (best_end, best_score):
                        best_end, best_score, best_move = start + 1, score, number
    return best_move


def transcribe(wav, api_key, moves):
    from openai import OpenAI

    client = OpenAI(api_key=api_key, timeout=TIMEOUT_SECONDS, max_retries=0)
    result = client.audio.transcriptions.create(
        model=voice.TRANSCRIBE_MODEL,
        file=("yell.wav", io.BytesIO(voice.clean_audio(wav)), "audio/wav"),
        prompt="Someone yelling attack names in a monster battle. The attacks: " + ", ".join(moves),
    )
    return result.text


def answer(wav, moves_header, transcriber=transcribe, key_loader=creatures.load_api_key, log=print):
    """Always returns a reply, because the game is waiting on it to finish the turn."""
    moves = [move.strip() for move in moves_header.split("|") if move.strip()]
    level = loudest_level(wav)
    if level < MIN_LEVEL:
        log(f"yell: too quiet to send (level {level:.0f}, need {MIN_LEVEL})")
        return "0\n"
    api_key = key_loader()
    if not api_key:
        return "0\n"
    try:
        transcript = transcriber(wav, api_key, moves).strip()
    except Exception as error:
        log(f"yell: transcription failed: {type(error).__name__}: {error}")
        return "0\n"
    number = match_move(transcript, moves)
    log(f'yell: level {level:.0f}, heard "{transcript}", move {number} of {moves}')
    return f"{number}\n{' '.join(transcript.split())}"
