"""Evaluate medication-adherence intent inference.

The default run evaluates the deterministic fallback and requires no external
model service. Use ``--include-llm`` to compare the configured LLM path.

Usage (from ``app/backend``):

    uv run python -m benchmark.intent
    uv run python -m benchmark.intent --include-llm
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

_BACKEND = Path(__file__).resolve().parent.parent
_SCRIPT_DIR = Path(__file__).resolve().parent
sys.path = [p for p in sys.path if Path(p).resolve() != _SCRIPT_DIR]
sys.path.insert(0, str(_BACKEND))

import intent

FIXTURE_PATH = _BACKEND / "tests" / "fixtures" / "intent_dialogues_100.json"
RESULTS_PATH = _SCRIPT_DIR / "json" / "results_intent.json"
EVALUATED_STATES = intent.INTENT_STATES[:-1]
QUALITY_GATE = 0.85
LLM_TIMEOUT_SECONDS = 30.0


def _confusion_matrix(rows: list[dict[str, Any]]) -> dict[str, dict[str, int]]:
    matrix = {
        label: {predicted: 0 for predicted in EVALUATED_STATES}
        for label in EVALUATED_STATES
    }
    for row in rows:
        matrix[row["expected"]][row["predicted"]] += 1
    return matrix


def _per_class_metrics(rows: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    metrics: dict[str, dict[str, float]] = {}
    for label in EVALUATED_STATES:
        tp = sum(
            row["expected"] == label and row["predicted"] == label
            for row in rows
        )
        fp = sum(
            row["expected"] != label and row["predicted"] == label
            for row in rows
        )
        fn = sum(
            row["expected"] == label and row["predicted"] != label
            for row in rows
        )
        support = sum(row["expected"] == label for row in rows)
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if precision + recall
            else 0.0
        )
        metrics[label] = {
            "precision": round(precision, 3),
            "recall": round(recall, 3),
            "f1": round(f1, 3),
            "support": support,
        }
    return metrics


def run_method(
    fixture: list[dict[str, str]],
    *,
    use_llm: bool,
    model: str | None = None,
) -> dict[str, Any]:
    """Run one inference path and return metrics plus row-level predictions."""
    rows: list[dict[str, Any]] = []
    latencies: list[float] = []
    for entry in fixture:
        started = time.perf_counter()
        if use_llm:
            result = (
                intent.classify_llm(
                    entry["transcript"],
                    timeout_s=LLM_TIMEOUT_SECONDS,
                    model=model,
                )
                or intent.classify_heuristic(entry["transcript"])
            )
        else:
            result = intent.classify_heuristic(entry["transcript"])
        elapsed_ms = (time.perf_counter() - started) * 1000
        latencies.append(elapsed_ms)
        rows.append(
            {
                "transcript": entry["transcript"],
                "expected": entry["label"],
                "predicted": result["state"],
                "correct": result["state"] == entry["label"],
                "method": result["method"],
                "latency_ms": round(elapsed_ms, 3),
            }
        )

    correct = sum(row["correct"] for row in rows)
    accuracy = correct / len(rows)
    p95_index = max(0, int(len(latencies) * 0.95) - 1)
    return {
        "method": "llm_with_fallback" if use_llm else "lexical_baseline",
        "n": len(rows),
        "correct": correct,
        "accuracy": round(accuracy, 4),
        "meets_quality_gate": accuracy >= QUALITY_GATE,
        "mean_latency_ms": round(sum(latencies) / len(latencies), 3),
        "p95_latency_ms": round(sorted(latencies)[p95_index], 3),
        "per_class": _per_class_metrics(rows),
        "confusion_matrix": _confusion_matrix(rows),
        "rows": rows,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Evaluate DoseLuma medication-adherence intent inference."
    )
    parser.add_argument(
        "--include-llm",
        action="store_true",
        help="also call the model provider configured in config.json",
    )
    parser.add_argument(
        "--model",
        help="override config.json's LLM model for this benchmark",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=RESULTS_PATH,
        help="JSON results path",
    )
    return parser.parse_args()


def main() -> None:
    args = _parse_args()
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    if not fixture:
        raise ValueError("evaluation fixture is empty")
    invalid_labels = {
        row["label"] for row in fixture if row["label"] not in EVALUATED_STATES
    }
    if invalid_labels:
        raise ValueError(f"unknown evaluation labels: {sorted(invalid_labels)}")

    reports = {
        "lexical_baseline": run_method(fixture, use_llm=False),
    }
    if args.include_llm:
        reports["llm_with_fallback"] = run_method(
            fixture,
            use_llm=True,
            model=args.model,
        )

    output = {
        "dataset": {
            "path": str(FIXTURE_PATH.relative_to(_BACKEND)),
            "source": "synthetic",
            "n": len(fixture),
            "quality_gate": QUALITY_GATE,
        },
        "reports": reports,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2), encoding="utf-8")

    print(f"Dataset: {len(fixture)} synthetic labelled dialogues")
    for name, report in reports.items():
        status = "PASS" if report["meets_quality_gate"] else "FAIL"
        print(
            f"{name}: accuracy={report['accuracy']:.1%} "
            f"({report['correct']}/{report['n']}), "
            f"p95={report['p95_latency_ms']:.3f} ms [{status}]"
        )
    print(f"Results: {args.output}")


if __name__ == "__main__":
    main()
