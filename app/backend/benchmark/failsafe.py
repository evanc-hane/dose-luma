"""Validate medication-safety and alert failure scenarios.

Executes four scripted scenarios 10 times against a real
SQLite database (adherence.py / caregiver_notify.py, unmocked except for
the outbound webhook/Twilio destinations) and reports the correct-behaviour
rate per scenario:

  (a) normal dose confirmation
  (b) a duplicate-dose attempt
  (c) distress-keyword detection
  (d) a missed dose with no response

Usage (from app/backend): uv run --no-project python -m benchmark.failsafe
"""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any
from unittest import mock

_BACKEND = Path(__file__).resolve().parent.parent
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path = [p for p in sys.path if Path(p).resolve() != _SCRIPT_DIR]
sys.path.insert(0, str(_BACKEND))

import adherence
import caregiver_notify
import db
import intent
import reminders

N_TRIALS = 10
RESULTS_PATH = _SCRIPT_DIR / "json" / "results_failsafe.json"


def _fresh_db() -> tempfile.TemporaryDirectory:
    tmp = tempfile.TemporaryDirectory()
    db.DB_PATH = Path(tmp.name) / "test.db"
    db.init_db()
    reminders.save_reminders({
        "enabled": True,
        "medications": [{"id": "med-1", "name": "Metformin", "time": "08:00"}],
    })
    return tmp


def scenario_normal_confirmation(trial: int) -> tuple[bool, str]:
    tmp = _fresh_db()
    try:
        now = datetime(2026, 7, 20, 8, 5)
        result = adherence.apply_intent("Taken", medication_id="med-1", transcript="Yes I took it", now=now)
        ok = result["action"] == "marked_taken" and not result["duplicate"] and result["locked"]
        return ok, f"action={result['action']} duplicate={result['duplicate']} locked={result['locked']}"
    finally:
        tmp.cleanup()


def scenario_duplicate_dose(trial: int) -> tuple[bool, str]:
    tmp = _fresh_db()
    try:
        now = datetime(2026, 7, 20, 8, 5)
        first = adherence.apply_intent("Taken", medication_id="med-1", transcript="Yes I took it", now=now)
        second = adherence.apply_intent(
            "Taken", medication_id="med-1", transcript="I took another one too", now=now
        )
        ok = (
            first["action"] == "marked_taken"
            and second["duplicate"] is True
            and second["action"] == "overdose_escalated"
            and second["alert"] is not None
            and second["alert"]["type"] == "overdose_risk"
        )
        return ok, f"first={first['action']} second.action={second['action']} second.duplicate={second['duplicate']}"
    finally:
        tmp.cleanup()


_DISTRESS_PHRASES = [
    "help I'm scared and in pain",
    "please help, I fell",
    "I have chest pain, this is an emergency",
    "I can't breathe, help me",
    "I'm really scared, something is wrong",
    "everything hurts and I'm afraid",
    "I fell down and I can't get up",
    "this is an emergency please help",
    "I need help right now, I'm hurt",
    "I'm in terrible pain, please",
]


def scenario_distress_detection(trial: int) -> tuple[bool, str]:
    tmp = _fresh_db()
    try:
        phrase = _DISTRESS_PHRASES[trial % len(_DISTRESS_PHRASES)]
        classified = intent.classify_heuristic(phrase)
        now = datetime(2026, 7, 20, 8, 5)
        result = adherence.apply_intent(
            classified["state"], medication_id="med-1", transcript=phrase, now=now
        )
        ok = (
            classified["state"] == "Distress"
            and result["alert"] is not None
            and result["alert"]["type"] == "distress"
            and result["alert"]["priority"] == "critical"
        )
        return ok, f"classified={classified['state']} alert_priority={result['alert']['priority'] if result['alert'] else None}"
    finally:
        tmp.cleanup()


def scenario_missed_no_response(trial: int) -> tuple[bool, str]:
    tmp = _fresh_db()
    try:
        # 90 minutes after the 08:00 scheduled time — 30min past the 60min
        # grace period, no dose ever logged.
        now = datetime(2026, 7, 20, 9, 30)
        created = adherence.sync_missed_alerts(now)
        ok = (
            len(created) == 1
            and created[0]["type"] == "missed"
            and created[0]["medication_id"] == "med-1"
        )
        # Second call within the same day must NOT re-create the alert.
        created_again = adherence.sync_missed_alerts(now)
        ok = ok and len(created_again) == 0
        return ok, f"created={len(created)} recreated_on_second_call={len(created_again)}"
    finally:
        tmp.cleanup()


SCENARIOS = {
    "a_normal_dose_confirmation": scenario_normal_confirmation,
    "b_duplicate_dose_attempt": scenario_duplicate_dose,
    "c_distress_keyword_detection": scenario_distress_detection,
    "d_missed_dose_no_response": scenario_missed_no_response,
}


def main() -> None:
    original_db_path = db.DB_PATH
    env_patch = mock.patch.dict(
        "os.environ",
        {
            "CAREGIVER_WEBHOOK_URL": "",
            "TWILIO_ACCOUNT_SID": "",
            "TWILIO_AUTH_TOKEN": "",
            "TWILIO_FROM_NUMBER": "",
            "CAREGIVER_PHONE_NUMBER": "",
            "SECONDARY_CONTACT_PHONE_NUMBER": "",
        },
        clear=False,
    )
    env_patch.start()
    try:
        report: dict[str, Any] = {}
        for name, fn in SCENARIOS.items():
            print(f"\n--- Scenario {name} ({N_TRIALS} trials) ---")
            trials: list[dict[str, Any]] = []
            for i in range(N_TRIALS):
                try:
                    ok, detail = fn(i)
                except Exception as exc:  # noqa: BLE001
                    ok, detail = False, f"EXCEPTION: {exc}"
                trials.append({"trial": i + 1, "passed": ok, "detail": detail})
                print(f"  trial {i + 1}/{N_TRIALS}: {'PASS' if ok else 'FAIL'} — {detail}")
            passed = sum(1 for t in trials if t["passed"])
            report[name] = {
                "n": N_TRIALS,
                "passed": passed,
                "correct_behaviour_rate": round(passed / N_TRIALS, 3),
                "trials": trials,
            }
    finally:
        env_patch.stop()
        db.DB_PATH = original_db_path

    RESULTS_PATH.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("\n=== Summary: correct-behaviour rate per scenario ===")
    for name, r in report.items():
        print(f"{name:35s} {r['correct_behaviour_rate']:.0%}  ({r['passed']}/{r['n']})")
    print(f"\nFull report written to {RESULTS_PATH}")


if __name__ == "__main__":
    main()
