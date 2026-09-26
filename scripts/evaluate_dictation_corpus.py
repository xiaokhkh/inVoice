#!/usr/bin/env python3
"""Evaluate fixed dictation-corpus results without uploading audio or text."""

import argparse
import json
import math
import re
import sys
import unicodedata
from collections import Counter
from pathlib import Path


REQUIRED_COUNTS = {"zh": 80, "en": 40, "mixed": 60, "terms": 20}


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for row, expected in enumerate(reference, start=1):
        current = [row]
        for column, actual in enumerate(hypothesis, start=1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[column] + 1,
                    previous[column - 1] + (expected != actual),
                )
            )
        previous = current
    return previous[-1]


def normalized_characters(text):
    return [
        char.lower()
        for char in unicodedata.normalize("NFKC", text)
        if not char.isspace() and not unicodedata.category(char).startswith(("P", "Z"))
    ]


def normalized_words(text):
    normalized = unicodedata.normalize("NFKC", text).lower()
    return re.findall(r"[\w.+/#:@-]+", normalized, flags=re.UNICODE)


def normalized_term(text):
    return "".join(normalized_characters(text))


def percentile95(values):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


def load_rows(path):
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            row = json.loads(line)
            for key in ("id", "category", "reference", "outputs"):
                if key not in row:
                    raise ValueError(f"line {line_number}: missing {key}")
            rows.append(row)
    return rows


def calculate(rows, model):
    char_errors = char_units = word_errors = word_units = 0
    retained_terms = total_terms = 0
    latencies = []
    missing = []
    for row in rows:
        output = row["outputs"].get(model)
        if not isinstance(output, dict) or "text" not in output:
            missing.append(row["id"])
            continue
        reference = row["reference"]
        hypothesis = output["text"]
        if row["category"] in ("zh", "mixed"):
            ref_chars = normalized_characters(reference)
            char_errors += edit_distance(ref_chars, normalized_characters(hypothesis))
            char_units += len(ref_chars)
        if row["category"] == "en":
            ref_words = normalized_words(reference)
            word_errors += edit_distance(ref_words, normalized_words(hypothesis))
            word_units += len(ref_words)
        normalized_hypothesis = normalized_term(hypothesis)
        for term in row.get("terms", []):
            total_terms += 1
            retained_terms += normalized_term(term) in normalized_hypothesis
        latency = output.get("stop_to_final_ms")
        if isinstance(latency, (int, float)):
            latencies.append(float(latency))
    return {
        "cer_zh_mixed": char_errors / char_units if char_units else None,
        "wer_en": word_errors / word_units if word_units else None,
        "term_retention": retained_terms / total_terms if total_terms else None,
        "stop_to_final_p95_ms": percentile95(latencies),
        "missing_result_count": len(missing),
        "missing_result_ids": missing[:20],
    }


def passes(candidate, baseline):
    checks = {
        "cer_within_2pp": (
            candidate["cer_zh_mixed"] is not None
            and baseline["cer_zh_mixed"] is not None
            and candidate["cer_zh_mixed"] <= baseline["cer_zh_mixed"] + 0.02
        ),
        "wer_within_2pp": (
            candidate["wer_en"] is not None
            and baseline["wer_en"] is not None
            and candidate["wer_en"] <= baseline["wer_en"] + 0.02
        ),
        "term_retention_at_least_95pct_of_glm": (
            candidate["term_retention"] is not None
            and baseline["term_retention"] is not None
            and candidate["term_retention"] >= baseline["term_retention"] * 0.95
        ),
        "stop_to_final_p95_at_most_250ms": (
            candidate["stop_to_final_p95_ms"] is not None
            and candidate["stop_to_final_p95_ms"] <= 250
        ),
        "all_results_present": candidate["missing_result_count"] == 0,
    }
    return checks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--baseline", default="glm")
    parser.add_argument("--candidate", action="append", required=True)
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()

    rows = load_rows(args.manifest)
    counts = Counter(row["category"] for row in rows)
    corpus_checks = {
        category: counts[category] >= required
        for category, required in REQUIRED_COUNTS.items()
    }
    baseline = calculate(rows, args.baseline)
    candidates = {}
    all_passed = all(corpus_checks.values()) and baseline["missing_result_count"] == 0
    for model in args.candidate:
        metrics = calculate(rows, model)
        checks = passes(metrics, baseline)
        candidates[model] = {"metrics": metrics, "checks": checks, "passed": all(checks.values())}
        all_passed = all_passed and candidates[model]["passed"]

    report = {
        "corpus": {
            "total": len(rows),
            "counts": dict(counts),
            "required": REQUIRED_COUNTS,
            "checks": corpus_checks,
        },
        "baseline": {"model": args.baseline, "metrics": baseline},
        "candidates": candidates,
        "passed": all_passed,
    }
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    if not args.report_only and not all_passed:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
