"""Measure TTS words per minute at different configured speed values.

The target is 120-140 wpm, slower than standard TTS output, to support older
adults who may benefit from a less hurried medication check-in.

Usage (from app/backend): uv run --no-project python -m benchmark.tts_speed
"""

from __future__ import annotations

import io
import json
import sys
import urllib.request
import wave
from pathlib import Path

_BACKEND = Path(__file__).resolve().parent.parent
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path = [p for p in sys.path if Path(p).resolve() != _SCRIPT_DIR]
sys.path.insert(0, str(_BACKEND))

import config

TEST_TEXT = "Hi there, it is time for your medication check-in. Have you taken your pills yet today?"
SPEEDS_TO_TEST = [1.0, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6]
TARGET_MIN_WPM = 120
TARGET_MAX_WPM = 140


def measure_wpm(text: str, speed: float) -> float:
    route = config.tts_route("en")
    url = f"{config.speech_base_url().rstrip('/')}/audio/speech"
    payload = {
        "model": route["model"], "voice": route["voice"],
        "input": text, "response_format": "wav", "speed": speed,
    }
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        audio = resp.read()
    with wave.open(io.BytesIO(audio)) as w:
        duration_s = w.getnframes() / w.getframerate()
    word_count = len(text.split())
    return word_count / (duration_s / 60)


def main() -> None:
    print(f'Test sentence ({len(TEST_TEXT.split())} words): "{TEST_TEXT}"')
    print(f"Target: {TARGET_MIN_WPM}-{TARGET_MAX_WPM} wpm\n")
    results = []
    for speed in SPEEDS_TO_TEST:
        wpm = measure_wpm(TEST_TEXT, speed)
        in_range = TARGET_MIN_WPM <= wpm <= TARGET_MAX_WPM
        results.append({"speed": speed, "wpm": round(wpm, 1), "in_target_range": in_range})
        print(f"  speed={speed:.2f}: {wpm:.1f} wpm  {'<- in target range' if in_range else ''}")

    best = min(results, key=lambda r: abs(r["wpm"] - (TARGET_MIN_WPM + TARGET_MAX_WPM) / 2))
    print(f"\nClosest to target midpoint ({(TARGET_MIN_WPM + TARGET_MAX_WPM) / 2} wpm): "
          f"speed={best['speed']} -> {best['wpm']} wpm")


if __name__ == "__main__":
    main()
