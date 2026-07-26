"""Regression gates for medication-adherence intent classification."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import intent  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "intent_dialogues.json"
EVALUATION_FIXTURES = Path(__file__).resolve().parent / "fixtures" / "intent_dialogues_100.json"


class TestIntentClassification(unittest.TestCase):
    def test_fixture_accuracy_heuristic_at_least_85_percent(self) -> None:
        rows = json.loads(FIXTURES.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(rows), 15)
        correct = 0
        for row in rows:
            result = intent.classify_utterance(row["transcript"], use_llm=False)
            if result["state"] == row["label"]:
                correct += 1
        accuracy = correct / len(rows)
        self.assertGreaterEqual(
            accuracy,
            0.85,
            f"accuracy={accuracy:.2%} correct={correct}/{len(rows)}",
        )

    def test_evaluation_set_accuracy_and_distress_recall(self) -> None:
        rows = json.loads(EVALUATION_FIXTURES.read_text(encoding="utf-8"))
        predictions = [
            intent.classify_utterance(row["transcript"], use_llm=False)["state"]
            for row in rows
        ]
        paired = list(zip(predictions, rows, strict=True))
        accuracy = sum(
            predicted == row["label"] for predicted, row in paired
        ) / len(rows)
        distress_rows = [
            (predicted, row)
            for predicted, row in paired
            if row["label"] == "Distress"
        ]
        distress_recall = sum(
            predicted == "Distress" for predicted, _ in distress_rows
        ) / len(distress_rows)

        self.assertGreaterEqual(accuracy, 0.85)
        self.assertGreaterEqual(distress_recall, 0.90)

    def test_empty_is_confused(self) -> None:
        result = intent.classify_heuristic("")
        self.assertEqual(result["state"], "Confused")

    def test_distress_beats_taken_keywords(self) -> None:
        # "help" should classify as Distress even if other words present
        result = intent.classify_heuristic("please help I took something wrong")
        self.assertEqual(result["state"], "Distress")


if __name__ == "__main__":
    unittest.main()
