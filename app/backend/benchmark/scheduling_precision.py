"""Measure scheduling precision across 50 accelerated events.

Measures the time difference between target initiation time and actual
firing time across 50 scheduled events, using the exact same scheduling
engine as scheduler.py's MedicationScheduler (APScheduler's
AsyncIOScheduler + CronTrigger) — but firing every 3 seconds instead of
once daily at a fixed HH:MM, since 50 real daily firings would take 50
days. This isolates the scheduler's own timing precision;
scheduler.py's own record_event()/drift tracking already covers the
*production* per-medication drift once deployed.

Usage (from app/backend): uv run --no-project python -m benchmark.scheduling_precision
"""

from __future__ import annotations

import asyncio
import json
import statistics
from datetime import datetime
from pathlib import Path

from apscheduler.events import EVENT_JOB_EXECUTED, JobExecutionEvent
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

N_EVENTS = 50
TARGET_DRIFT_SECONDS = 30
MAX_DRIFT_SECONDS = 60
RESULTS_PATH = Path(__file__).resolve().parent / "json" / "results_scheduling.json"

samples: list[float] = []
done = asyncio.Event()


async def _noop_job() -> None:
    pass


def _on_executed(event: JobExecutionEvent) -> None:
    now = datetime.now(tz=event.scheduled_run_time.tzinfo)
    drift = (now - event.scheduled_run_time).total_seconds()
    samples.append(drift)
    print(f"  event {len(samples)}/{N_EVENTS}: drift={drift * 1000:+.1f}ms")
    if len(samples) >= N_EVENTS:
        done.set()


async def main() -> None:
    scheduler = AsyncIOScheduler()
    scheduler.add_listener(_on_executed, EVENT_JOB_EXECUTED)
    scheduler.add_job(_noop_job, CronTrigger(second="*/3"), id="precision-test", misfire_grace_time=10)
    scheduler.start()

    print(f"Collecting {N_EVENTS} scheduled-firing samples (~{N_EVENTS * 3}s)...")
    await done.wait()
    scheduler.shutdown(wait=False)

    mean_drift = statistics.mean(samples)
    abs_samples = [abs(s) for s in samples]
    mean_abs_drift = statistics.mean(abs_samples)
    max_abs_drift = max(abs_samples)

    report = {
        "n": len(samples),
        "mean_drift_seconds": round(mean_drift, 4),
        "mean_abs_drift_seconds": round(mean_abs_drift, 4),
        "max_abs_drift_seconds": round(max_abs_drift, 4),
        "stdev_seconds": round(statistics.stdev(samples), 4) if len(samples) > 1 else 0.0,
        "meets_target_30s": max_abs_drift <= TARGET_DRIFT_SECONDS,
        "meets_max_60s": max_abs_drift <= MAX_DRIFT_SECONDS,
        "samples_seconds": [round(s, 4) for s in samples],
        "note": (
            "CronTrigger(second='*/3') on the real AsyncIOScheduler (same engine "
            "as scheduler.py's MedicationScheduler), not actual daily HH:MM "
            "medication times — see module docstring."
        ),
    }
    RESULTS_PATH.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("\n=== Summary (target: <=30s, maximum: <=60s) ===")
    print(f"mean drift:     {report['mean_drift_seconds'] * 1000:+.1f}ms")
    print(f"mean |drift|:   {report['mean_abs_drift_seconds'] * 1000:.1f}ms")
    print(f"max |drift|:    {report['max_abs_drift_seconds'] * 1000:.1f}ms")
    print(f"stdev:          {report['stdev_seconds'] * 1000:.1f}ms")
    status = "PASS" if report["meets_target_30s"] else ("MIN-OK" if report["meets_max_60s"] else "FAIL")
    print(f"[{status}]")
    print(f"\nFull report written to {RESULTS_PATH}")


if __name__ == "__main__":
    asyncio.run(main())
