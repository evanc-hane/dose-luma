"""Measure voice-pipeline latency against configured model services.

Measures each component's real latency against the currently configured,
deployed services — Cerebras Cloud (LLM) and ElevenLabs (STT + TTS) — not
simulated. Total latency is approximated as STT + LLM + TTS and compared
with a 400ms target and 700ms maximum budget.

Caveat: this script measures the real network available to the host and does
not emulate alternate bandwidth or packet-loss conditions.

Usage (from app/backend): uv run --no-project python -m benchmark.latency
"""

from __future__ import annotations

import json
import os
import statistics
import sys
import time
import urllib.request
from pathlib import Path

from dotenv import load_dotenv

_BACKEND = Path(__file__).resolve().parent.parent
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path = [p for p in sys.path if Path(p).resolve() != _SCRIPT_DIR]
sys.path.insert(0, str(_BACKEND))

import config

load_dotenv()  # picks up ELEVEN_API_KEY / CEREBRAS_API_KEY from repo-root .env

N_TRIALS = 10

TEST_SENTENCES = [
    "Yes, I took it already.",
    "Hi there, it's time for your medication check-in.",
    "I'm not sure which pill to take.",
]

RESULTS_PATH = _SCRIPT_DIR / "json" / "results_latency.json"


def _tts_call(text: str) -> tuple[float, bytes]:
    cfg = config._section("tts")
    api_key = os.environ["ELEVEN_API_KEY"]
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{cfg['voice_id']}"
    payload = {"text": text, "model_id": "eleven_turbo_v2_5"}
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"xi-api-key": api_key, "Content-Type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as resp:
        audio_bytes = resp.read()
    return (time.perf_counter() - started) * 1000, audio_bytes


def _stt_call(audio_bytes: bytes) -> float:
    cfg = config._section("stt")
    api_key = os.environ["ELEVEN_API_KEY"]
    url = "https://api.elevenlabs.io/v1/speech-to-text"
    boundary = "----doselumabenchmark"
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\n{cfg['model_id']}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\n"
        f"Content-Type: audio/mpeg\r\n\r\n".encode(),
        audio_bytes,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    body = b"".join(parts)
    req = urllib.request.Request(
        url, data=body,
        headers={"xi-api-key": api_key, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()
    return (time.perf_counter() - started) * 1000


def _llm_call(user_text: str) -> float:
    base = config.llm_base_url().rstrip("/")
    api_key = os.environ["CEREBRAS_API_KEY"]
    payload = {
        "model": config.llm_model(),
        "messages": [
            {"role": "system", "content": "You are ALI, a warm medication check-in assistant. Reply in one short sentence."},
            {"role": "user", "content": user_text},
        ],
        "temperature": 0.3,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{base}/chat/completions", data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            # Cerebras's WAF 403s Python's default urllib User-Agent.
            "User-Agent": "doseluma-backend/1.0",
        },
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(req, timeout=60) as resp:
        resp.read()
    return (time.perf_counter() - started) * 1000


def summarize(name: str, values: list[float]) -> dict:
    ordered = sorted(values)
    return {
        "component": name,
        "n": len(values),
        "mean_ms": round(statistics.mean(values), 1),
        "p95_ms": round(ordered[max(0, int(len(ordered) * 0.95) - 1)], 1),
        "min_ms": round(min(values), 1),
        "max_ms": round(max(values), 1),
    }


def main() -> None:
    print(f"Running {N_TRIALS} trials per component against Cerebras (LLM) + ElevenLabs (STT/TTS)...")

    tts_latencies: list[float] = []
    audio_samples: list[bytes] = []
    for i in range(N_TRIALS):
        text = TEST_SENTENCES[i % len(TEST_SENTENCES)]
        ms, audio = _tts_call(text)
        tts_latencies.append(ms)
        audio_samples.append(audio)
        print(f"  TTS trial {i + 1}/{N_TRIALS}: {ms:.0f}ms ({len(audio)} bytes)")

    stt_latencies: list[float] = []
    for i, audio in enumerate(audio_samples):
        ms = _stt_call(audio)
        stt_latencies.append(ms)
        print(f"  STT trial {i + 1}/{N_TRIALS}: {ms:.0f}ms")

    llm_latencies: list[float] = []
    for i in range(N_TRIALS):
        text = TEST_SENTENCES[i % len(TEST_SENTENCES)]
        ms = _llm_call(text)
        llm_latencies.append(ms)
        print(f"  LLM trial {i + 1}/{N_TRIALS}: {ms:.0f}ms")

    report = {
        "stt": summarize("STT", stt_latencies),
        "llm": summarize("LLM", llm_latencies),
        "tts": summarize("TTS", tts_latencies),
    }
    report["total_mean_ms"] = round(
        report["stt"]["mean_ms"] + report["llm"]["mean_ms"] + report["tts"]["mean_ms"], 1
    )
    report["meets_target_400ms"] = report["total_mean_ms"] < 400
    report["meets_max_700ms"] = report["total_mean_ms"] < 700
    report["stack"] = "Cerebras (gpt-oss-120b) + ElevenLabs (scribe_v1 STT, eleven_turbo_v2_5 TTS)"
    report["caveat"] = (
        "Measured over the real internet connection this machine has right now, "
        "single-process HTTP round-trips (not the streaming LiveKit pipeline's "
        "internal TTFT/TTFB timers, which are typically lower). This script "
        "does not perform network traffic shaping."
    )

    with open(RESULTS_PATH, "w") as f:
        json.dump(report, f, indent=2)

    print("\n=== Summary (target: <400ms, maximum: <700ms) ===")
    for key in ("stt", "llm", "tts"):
        r = report[key]
        print(f"{r['component']:5s} mean={r['mean_ms']}ms p95={r['p95_ms']}ms min={r['min_ms']}ms max={r['max_ms']}ms")
    status = "PASS" if report["meets_target_400ms"] else ("MIN-OK" if report["meets_max_700ms"] else "FAIL")
    print(f"TOTAL mean={report['total_mean_ms']}ms  [{status}]")
    print(f"\nFull report written to {RESULTS_PATH}")
    print(f"\nCaveat: {report['caveat']}")


if __name__ == "__main__":
    main()
