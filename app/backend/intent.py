"""Hybrid LLM/lexical intent classification for medication adherence.

States: Taken | Refused | Delayed | Confused | Distress
"""

from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any, Literal

import config
import db

logger = logging.getLogger(__name__)

IntentState = Literal["Taken", "Refused", "Delayed", "Confused", "Distress", "NoResponse"]
INTENT_STATES: tuple[IntentState, ...] = (
    "Taken",
    "Refused",
    "Delayed",
    "Confused",
    "Distress",
    # Not something a patient says — the voice agent reports this itself
    # (SilenceWatchdog) when repeated nudges get no response at all, i.e.
    # nobody is there to answer the call.
    "NoResponse",
)

_MAX_LOG_ENTRIES = 500

_CLASSIFY_SYSTEM = (
    "You classify medication adherence replies from older adults. "
    "Reply with ONLY a JSON object: "
    '{"state":"Taken|Refused|Delayed|Confused|Distress","confidence":0.0,"rationale":"..."}. '
    "Taken = they took (or will immediately take) the dose. "
    "Refused = they will not take it. "
    "Delayed = they will take it later. "
    "Confused = unsure what to do / which pill. "
    "Distress = scared, in pain, emergency, very upset."
)

# Deterministic lexical baseline. Order matters: safety-critical distress and
# uncertainty take precedence over medication-adherence states.
_HEURISTICS: list[tuple[IntentState, tuple[str, ...]]] = [
    (
        "Distress",
        (
            "help",
            "scared",
            "afraid",
            "hurt",
            "pain",
            "emergency",
            "chest",
            "can't breathe",
            "cant breathe",
            "falling",
            "fell",
            "911",
            "don't feel right",
            "something is wrong",
            "feels very wrong",
            "heart is racing",
            "frightened",
            "dizzy",
            "can't get up",
            "cant get up",
            "can't feel",
            "cant feel",
            "need help",
            "call someone",
            "bad is happening",
            "doesn't feel normal",
            "doesnt feel normal",
        ),
    ),
    (
        "Confused",
        (
            "confused",
            "not sure",
            "don't know",
            "dont know",
            "which pill",
            "what medication",
            "forgot which",
            "unsure",
            "supposed to",
            "what these are for",
            "same one as",
            "can't remember",
            "cant remember",
            "what is this",
            "don't understand",
            "dont understand",
            "mixed up",
            "doctor say",
            "i'm lost",
            "im lost",
            "can't tell",
            "cant tell",
            "don't remember",
            "dont remember",
            "not sure honestly",
            "blue one or",
        ),
    ),
    (
        "Refused",
        (
            "won't take",
            "wont take",
            "won't",
            "refuse",
            "not taking",
            "don't want",
            "dont want",
            "no i will not",
            "no i won't",
            "absolutely not",
            "pass on",
            "decided i'm done",
            "decided im done",
            "not interested",
            "don't think so",
            "dont think so",
            "no way",
            "skipping",
            "said no",
            "rather not",
            "nope",
            "choosing not",
            "no dice",
            "refusing",
            "not now, not ever",
            "not touching",
        ),
    ),
    (
        "Delayed",
        (
            "later",
            "in a bit",
            "not yet",
            "in an hour",
            "wait",
            "soon",
            "remind me",
            "i'll take",
            "ill take",
            "give me",
            "in a little while",
            "finish my",
            "once i'm",
            "once im",
            "ask me again",
            "not ready yet",
            "hold that thought",
            "get to it",
            "before bed",
            "something first",
            "not right now",
            "not this second",
            "daughter calls",
        ),
    ),
    (
        "Taken",
        (
            "yes",
            "i did",
            "i have",
            "already took",
            "took it",
            "taken",
            "all done",
            "finished",
            "just took",
            "i took",
            "swallowed",
            "took care of",
            "done and done",
            "i had it",
            "sure did",
            "that's taken care of",
            "thats taken care of",
            "popped the pill",
            "already did",
            "consider it done",
            "had my tablets",
            "washed it down",
            "right on schedule",
            "i remembered",
        ),
    ),
]


def classify_heuristic(transcript: str) -> dict[str, Any]:
    """Rule-based classifier (always available; used as fallback / fixture path)."""
    text = (transcript or "").strip().lower()
    if not text:
        return {
            "state": "Confused",
            "confidence": 0.4,
            "rationale": "empty utterance",
            "method": "heuristic",
        }
    for state, needles in _HEURISTICS:
        for needle in needles:
            if needle in text:
                return {
                    "state": state,
                    "confidence": 0.85,
                    "rationale": f"matched {needle!r}",
                    "method": "heuristic",
                }
    return {
        "state": "Confused",
        "confidence": 0.5,
        "rationale": "no strong keyword match",
        "method": "heuristic",
    }


def _parse_llm_json(raw: str) -> dict[str, Any] | None:
    raw = raw.strip()
    # Strip common markdown fences
    if raw.startswith("```"):
        raw = re.sub(r"^```(?:json)?\s*", "", raw)
        raw = re.sub(r"\s*```$", "", raw)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        match = re.search(r"\{.*\}", raw, re.DOTALL)
        if not match:
            return None
        try:
            data = json.loads(match.group(0))
        except json.JSONDecodeError:
            return None
    state = str(data.get("state", "")).strip()
    # Normalize casing
    for allowed in INTENT_STATES:
        if state.lower() == allowed.lower():
            conf = float(data.get("confidence", 0.7))
            return {
                "state": allowed,
                "confidence": max(0.0, min(1.0, conf)),
                "rationale": str(data.get("rationale", "")),
                "method": "llm",
            }
    return None


def classify_llm(transcript: str, timeout_s: float = 8.0, model: str | None = None) -> dict[str, Any] | None:
    """Call local OpenAI-compatible chat API. Returns None on failure.

    `model` overrides config.json's configured model — used by
    benchmark/intent.py to compare against a different local model without
    touching the deployed configuration.
    """
    try:
        base = config.llm_base_url().rstrip("/")
        model = model or config.llm_model()
    except Exception as exc:  # noqa: BLE001
        logger.warning("intent LLM config unavailable: %s", exc)
        return None

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": _CLASSIFY_SYSTEM},
            {"role": "user", "content": transcript},
        ],
        "temperature": 0.0,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {config.llm_api_key()}",
            # Cloud providers (Cerebras) sit behind a WAF that 403s Python's
            # default urllib User-Agent — a real one is required, not just a
            # valid API key.
            "User-Agent": "doseluma-backend/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            body = json.loads(resp.read().decode("utf-8"))
        content = body["choices"][0]["message"]["content"]
        return _parse_llm_json(content)
    # TimeoutError is raised bare (not wrapped in URLError) when the read
    # itself times out after the connection is already open — it must be
    # caught explicitly or a slow/overloaded local LLM crashes the caller
    # instead of falling back to the heuristic classifier.
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        logger.info("intent LLM classify failed, using heuristic: %s", exc)
        return None


def classify_utterance(transcript: str, *, use_llm: bool = True) -> dict[str, Any]:
    """Classify transcript into one of the five adherence states."""
    if use_llm:
        llm_result = classify_llm(transcript)
        if llm_result is not None:
            return llm_result
    return classify_heuristic(transcript)


def append_intent_log(entry: dict[str, Any]) -> None:
    conn = db.get_connection()
    try:
        conn.execute(
            "INSERT INTO intent_log "
            "(ts, date, medication_id, transcript, state, confidence, rationale, method) "
            "VALUES (:ts, :date, :medication_id, :transcript, :state, :confidence, :rationale, :method)",
            entry,
        )
        # Cap: keep only the most recently inserted _MAX_LOG_ENTRIES rows.
        conn.execute(
            "DELETE FROM intent_log WHERE seq IN ("
            "  SELECT seq FROM intent_log ORDER BY seq DESC LIMIT -1 OFFSET ?"
            ")",
            (_MAX_LOG_ENTRIES,),
        )
        conn.commit()
    finally:
        conn.close()


def log_classification(
    *,
    transcript: str,
    result: dict[str, Any],
    medication_id: str | None,
    now: datetime | None = None,
) -> dict[str, Any]:
    now = now or datetime.now()
    entry = {
        "ts": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "medication_id": medication_id or "",
        "transcript": transcript,
        "state": result["state"],
        "confidence": result["confidence"],
        "rationale": result.get("rationale", ""),
        "method": result.get("method", ""),
    }
    append_intent_log(entry)
    return entry
