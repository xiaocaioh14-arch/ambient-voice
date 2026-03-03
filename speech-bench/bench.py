#!/usr/bin/env python3
"""ASR benchmark runner.
Compare different ASR configurations and post-processing strategies.

Usage:
    python bench.py --config configs/baseline.json --config configs/with_adapter.json --audio_dir test_audio/
    python bench.py --config configs/baseline.json --reference reference.jsonl --output results/
"""

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def parse_args():
    parser = argparse.ArgumentParser(description="ASR benchmark runner")
    parser.add_argument("--config", type=str, action="append", required=True,
                        help="Path to ASR config JSON (can specify multiple)")
    parser.add_argument("--audio_dir", type=str, default=None,
                        help="Directory containing test audio files")
    parser.add_argument("--reference", type=str, default=None,
                        help="Reference transcriptions JSONL")
    parser.add_argument("--output", type=str, default="results/",
                        help="Output directory for results")
    parser.add_argument("--runs", type=int, default=1,
                        help="Number of runs per configuration (for latency averaging)")
    return parser.parse_args()


def load_config(path: str) -> dict:
    """Load ASR configuration from JSON."""
    with open(path) as f:
        config = json.load(f)
    config["_config_path"] = path
    config["_config_name"] = Path(path).stem
    return config


def load_reference(path: str) -> dict[str, str]:
    """Load reference transcriptions as {filename: text} mapping."""
    refs = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            filename = item.get("file", item.get("filename", ""))
            text = item.get("text", item.get("transcription", ""))
            if filename and text:
                refs[filename] = text
    return refs


def compute_cer(reference: str, hypothesis: str) -> float:
    """Character Error Rate via edit distance."""
    if not reference:
        return 0.0 if not hypothesis else 1.0

    ref = list(reference)
    hyp = list(hypothesis)
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


def run_benchmark(config: dict, audio_files: list[str], reference: dict[str, str] | None, runs: int) -> dict:
    """Run benchmark for a single configuration.

    This is a framework - actual ASR invocation depends on the config provider.
    Currently supports result files for offline comparison.
    """
    config_name = config["_config_name"]
    logger.info(f"Running benchmark: {config_name}")

    results = {
        "config_name": config_name,
        "config": {k: v for k, v in config.items() if not k.startswith("_")},
        "transcriptions": [],
        "metrics": {},
    }

    # Check for pre-computed results (offline mode)
    results_file = config.get("results_file")
    if results_file and os.path.exists(results_file):
        logger.info(f"Loading pre-computed results from {results_file}")
        with open(results_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                item = json.loads(line)
                results["transcriptions"].append(item)
    else:
        # Placeholder for live ASR invocation
        logger.warning(f"No results_file in config and live ASR not implemented")
        logger.warning("Add 'results_file' to config JSON pointing to transcription JSONL")
        return results

    # Compute metrics against reference
    if reference:
        total_cer = 0.0
        matched = 0
        for t in results["transcriptions"]:
            filename = t.get("file", t.get("filename", ""))
            hypothesis = t.get("text", t.get("transcription", ""))
            if filename in reference:
                cer = compute_cer(reference[filename], hypothesis)
                t["cer"] = round(cer, 4)
                total_cer += cer
                matched += 1

        if matched > 0:
            results["metrics"]["avg_cer"] = round(total_cer / matched, 4)
            results["metrics"]["matched_files"] = matched

    # Latency metrics
    latencies = [t.get("latency_ms", 0) for t in results["transcriptions"] if "latency_ms" in t]
    if latencies:
        results["metrics"]["avg_latency_ms"] = round(sum(latencies) / len(latencies), 1)
        results["metrics"]["p95_latency_ms"] = round(sorted(latencies)[int(len(latencies) * 0.95)], 1)

    results["metrics"]["total_files"] = len(results["transcriptions"])
    return results


def print_comparison(all_results: list[dict]):
    """Print comparison table of benchmark results."""
    print("\n## Benchmark Comparison\n")
    print("| Config | Files | Avg CER | Avg Latency (ms) | P95 Latency (ms) |")
    print("|--------|-------|---------|-------------------|-------------------|")

    for r in all_results:
        m = r["metrics"]
        name = r["config_name"]
        files = m.get("total_files", 0)
        cer = f"{m['avg_cer']:.4f}" if "avg_cer" in m else "N/A"
        avg_lat = f"{m['avg_latency_ms']:.0f}" if "avg_latency_ms" in m else "N/A"
        p95_lat = f"{m['p95_latency_ms']:.0f}" if "p95_latency_ms" in m else "N/A"
        print(f"| {name} | {files} | {cer} | {avg_lat} | {p95_lat} |")


def main():
    args = parse_args()
    os.makedirs(args.output, exist_ok=True)

    # Load configs
    configs = [load_config(c) for c in args.config]
    logger.info(f"Loaded {len(configs)} configurations")

    # Load reference
    reference = None
    if args.reference:
        reference = load_reference(args.reference)
        logger.info(f"Loaded {len(reference)} reference transcriptions")

    # Collect audio files
    audio_files = []
    if args.audio_dir and os.path.isdir(args.audio_dir):
        exts = {".wav", ".mp3", ".m4a", ".flac", ".ogg"}
        audio_files = sorted(
            str(p) for p in Path(args.audio_dir).glob("*") if p.suffix.lower() in exts
        )
        logger.info(f"Found {len(audio_files)} audio files")

    # Run benchmarks
    all_results = []
    for config in configs:
        result = run_benchmark(config, audio_files, reference, args.runs)
        all_results.append(result)

    # Output
    print_comparison(all_results)

    # Save detailed results
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_file = os.path.join(args.output, f"bench_{timestamp}.json")
    with open(output_file, "w") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    logger.info(f"Saved results to {output_file}")


if __name__ == "__main__":
    main()
