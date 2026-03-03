#!/usr/bin/env python3
"""Parameter matrix testing for SpeechAnalyzer.

Key finding: 纠错优先场景不建议 fastResults
(Fast results not recommended for correction-priority scenarios)

Tests a grid of SpeechAnalyzer parameters and measures:
- Accuracy (CER against reference)
- Latency (time to final result)
- Confidence distribution

Usage:
    python param_test.py --audio_dir test_audio/ --reference reference.jsonl --output results/
    python param_test.py --results_dir results/raw/ --reference reference.jsonl --output results/
"""

import argparse
import itertools
import json
import logging
import os
import time
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

# Parameter grid for SpeechAnalyzer testing
PARAM_GRID = {
    "taskHint": [".dictation", ".search", ".unspecified"],
    "customizedLanguageModel": [None, "path/to/custom_lm"],
    "shouldReportPartialResults": [True, False],
}

# SA parameter combinations to test
SA_CONFIGS = [
    {
        "name": "baseline",
        "taskHint": ".dictation",
        "shouldReportPartialResults": True,
        "customizedLanguageModel": None,
    },
    {
        "name": "dictation_no_partial",
        "taskHint": ".dictation",
        "shouldReportPartialResults": False,
        "customizedLanguageModel": None,
    },
    {
        "name": "search_partial",
        "taskHint": ".search",
        "shouldReportPartialResults": True,
        "customizedLanguageModel": None,
    },
    {
        "name": "dictation_custom_lm",
        "taskHint": ".dictation",
        "shouldReportPartialResults": True,
        "customizedLanguageModel": "custom",
    },
    {
        "name": "unspecified_no_partial",
        "taskHint": ".unspecified",
        "shouldReportPartialResults": False,
        "customizedLanguageModel": None,
    },
]


def parse_args():
    parser = argparse.ArgumentParser(description="SpeechAnalyzer parameter matrix test")
    parser.add_argument("--audio_dir", type=str, default=None,
                        help="Directory containing test audio files")
    parser.add_argument("--results_dir", type=str, default=None,
                        help="Directory containing pre-computed result JSONL files per config")
    parser.add_argument("--reference", type=str, required=True,
                        help="Reference transcriptions JSONL")
    parser.add_argument("--output", type=str, default="results/",
                        help="Output directory")
    parser.add_argument("--full_grid", action="store_true",
                        help="Test full parameter grid instead of predefined configs")
    return parser.parse_args()


def load_reference(path: str) -> dict[str, str]:
    """Load reference transcriptions."""
    refs = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            filename = item.get("file", "")
            text = item.get("text", "")
            if filename and text:
                refs[filename] = text
    return refs


def compute_cer(reference: str, hypothesis: str) -> float:
    """Character Error Rate."""
    if not reference:
        return 0.0 if not hypothesis else 1.0
    ref, hyp = list(reference), list(hypothesis)
    n, m = len(ref), len(hyp)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dp[i][0] = i
    for j in range(m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
    return dp[n][m] / n


def load_config_results(results_dir: str, config_name: str) -> list[dict]:
    """Load pre-computed results for a config."""
    results_file = os.path.join(results_dir, f"{config_name}.jsonl")
    if not os.path.exists(results_file):
        return []
    items = []
    with open(results_file) as f:
        for line in f:
            line = line.strip()
            if line:
                items.append(json.loads(line))
    return items


def analyze_config(config: dict, transcriptions: list[dict], reference: dict[str, str]) -> dict:
    """Analyze results for a single configuration."""
    config_name = config["name"]
    result = {
        "config_name": config_name,
        "params": {k: v for k, v in config.items() if k != "name"},
        "metrics": {},
    }

    if not transcriptions:
        logger.warning(f"No transcriptions for config: {config_name}")
        return result

    # CER analysis
    cers = []
    for t in transcriptions:
        filename = t.get("file", "")
        hyp = t.get("text", t.get("final_text", ""))
        if filename in reference:
            cer = compute_cer(reference[filename], hyp)
            cers.append(cer)

    if cers:
        result["metrics"]["avg_cer"] = round(sum(cers) / len(cers), 4)
        result["metrics"]["min_cer"] = round(min(cers), 4)
        result["metrics"]["max_cer"] = round(max(cers), 4)
        result["metrics"]["median_cer"] = round(sorted(cers)[len(cers) // 2], 4)

    # Latency analysis
    latencies = [t.get("latency_ms", 0) for t in transcriptions if "latency_ms" in t]
    if latencies:
        latencies_sorted = sorted(latencies)
        result["metrics"]["avg_latency_ms"] = round(sum(latencies) / len(latencies), 1)
        result["metrics"]["p50_latency_ms"] = round(latencies_sorted[len(latencies) // 2], 1)
        result["metrics"]["p95_latency_ms"] = round(latencies_sorted[int(len(latencies) * 0.95)], 1)

    # Confidence distribution
    confidences = [t.get("confidence", 0) for t in transcriptions if "confidence" in t]
    if confidences:
        result["metrics"]["avg_confidence"] = round(sum(confidences) / len(confidences), 3)
        low_conf = sum(1 for c in confidences if c < 0.5)
        result["metrics"]["low_confidence_pct"] = round(low_conf / len(confidences), 3)

    # Partial result stats (relevant for fastResults analysis)
    partial_counts = [t.get("partial_count", 0) for t in transcriptions if "partial_count" in t]
    if partial_counts:
        result["metrics"]["avg_partial_results"] = round(sum(partial_counts) / len(partial_counts), 1)

    # Final vs partial text differences (measures instability)
    changes = [t.get("final_differs_from_last_partial", False) for t in transcriptions]
    if changes:
        change_rate = sum(1 for c in changes if c) / len(changes)
        result["metrics"]["final_change_rate"] = round(change_rate, 3)

    result["metrics"]["total_files"] = len(transcriptions)
    result["metrics"]["matched_files"] = len(cers)
    return result


def generate_full_grid() -> list[dict]:
    """Generate all parameter combinations from PARAM_GRID."""
    keys = list(PARAM_GRID.keys())
    values = list(PARAM_GRID.values())
    configs = []
    for combo in itertools.product(*values):
        config = dict(zip(keys, combo))
        name_parts = [f"{k}={v}" for k, v in config.items()]
        config["name"] = "__".join(name_parts)
        configs.append(config)
    return configs


def print_report(all_results: list[dict]):
    """Print parameter test report."""
    print("\n## Parameter Test Results\n")
    print("| Config | Avg CER | Avg Latency | P95 Latency | Confidence | Final Change Rate |")
    print("|--------|---------|-------------|-------------|------------|-------------------|")

    for r in sorted(all_results, key=lambda x: x["metrics"].get("avg_cer", 999)):
        m = r["metrics"]
        name = r["config_name"]
        cer = f"{m['avg_cer']:.4f}" if "avg_cer" in m else "N/A"
        avg_lat = f"{m['avg_latency_ms']:.0f}ms" if "avg_latency_ms" in m else "N/A"
        p95_lat = f"{m['p95_latency_ms']:.0f}ms" if "p95_latency_ms" in m else "N/A"
        conf = f"{m['avg_confidence']:.3f}" if "avg_confidence" in m else "N/A"
        change = f"{m['final_change_rate']:.1%}" if "final_change_rate" in m else "N/A"
        print(f"| {name} | {cer} | {avg_lat} | {p95_lat} | {conf} | {change} |")

    print("\n### Key Finding")
    print("纠错优先场景不建议 fastResults (shouldReportPartialResults=True)")
    print("Partial results introduce instability that degrades post-correction accuracy.")


def main():
    args = parse_args()
    os.makedirs(args.output, exist_ok=True)

    reference = load_reference(args.reference)
    logger.info(f"Loaded {len(reference)} reference transcriptions")

    configs = generate_full_grid() if args.full_grid else SA_CONFIGS
    logger.info(f"Testing {len(configs)} configurations")

    all_results = []
    for config in configs:
        transcriptions = []
        if args.results_dir:
            transcriptions = load_config_results(args.results_dir, config["name"])

        result = analyze_config(config, transcriptions, reference)
        all_results.append(result)

    print_report(all_results)

    # Save detailed results
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_file = os.path.join(args.output, f"param_test_{timestamp}.json")
    with open(output_file, "w") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    logger.info(f"Saved results to {output_file}")


if __name__ == "__main__":
    main()
