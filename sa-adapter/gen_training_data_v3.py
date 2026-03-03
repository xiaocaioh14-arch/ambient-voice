#!/usr/bin/env python3
"""Generate training data from multiple sources.

Sources:
1. Human corrections (from ~/.we/corrections.jsonl)
2. Gemini-generated synthetic pairs
3. Auto-pass (correct transcriptions used as identity examples)
4. Domain-specific synthetic data

Usage:
    python gen_training_data_v3.py --corrections_dir /path/to/corrections --output train_v3/
    python gen_training_data_v3.py --corrections_dir /path/to/corrections --output train_v3/ --min_quality 0.7
"""

import argparse
import json
import logging
import os
import random
from collections import Counter
from pathlib import Path

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

DEFAULT_QUALITY_THRESHOLD = 0.5
DEFAULT_IDENTITY_RATIO = 0.15
DEFAULT_SYNTHETIC_RATIO = 0.30


def parse_args():
    parser = argparse.ArgumentParser(description="Generate training data v3")
    parser.add_argument("--corrections_dir", type=str, required=True,
                        help="Directory containing corrections.jsonl files")
    parser.add_argument("--synthetic_dir", type=str, default=None,
                        help="Directory containing synthetic training pairs")
    parser.add_argument("--output", type=str, required=True,
                        help="Output directory for training data")
    parser.add_argument("--min_quality", type=float, default=DEFAULT_QUALITY_THRESHOLD,
                        help="Minimum quality score for corrections")
    parser.add_argument("--identity_ratio", type=float, default=DEFAULT_IDENTITY_RATIO,
                        help="Ratio of identity examples (input == output)")
    parser.add_argument("--synthetic_ratio", type=float, default=DEFAULT_SYNTHETIC_RATIO,
                        help="Ratio of synthetic examples in final mix")
    parser.add_argument("--max_pairs", type=int, default=None,
                        help="Maximum total training pairs")
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def load_corrections(corrections_dir: str, min_quality: float) -> list[dict]:
    """Load human corrections from JSONL files, filtering by quality."""
    pairs = []
    corrections_path = Path(corrections_dir)

    jsonl_files = list(corrections_path.glob("**/corrections.jsonl"))
    if not jsonl_files:
        jsonl_files = list(corrections_path.glob("**/*.jsonl"))

    for jsonl_file in sorted(jsonl_files):
        logger.info(f"Reading corrections from {jsonl_file}")
        with open(jsonl_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # Extract correction pair
                raw = item.get("raw", item.get("input", "")).strip()
                corrected = item.get("corrected", item.get("output", "")).strip()
                quality = item.get("quality", 1.0)

                if not raw or not corrected:
                    continue
                if quality < min_quality:
                    continue

                pairs.append({
                    "input": raw,
                    "output": corrected,
                    "source": "human",
                })

    logger.info(f"Loaded {len(pairs)} human corrections (quality >= {min_quality})")
    return pairs


def load_synthetic(synthetic_dir: str) -> list[dict]:
    """Load synthetic training pairs (Gemini-generated or domain-specific)."""
    pairs = []
    if not synthetic_dir or not os.path.isdir(synthetic_dir):
        return pairs

    synthetic_path = Path(synthetic_dir)
    for jsonl_file in sorted(synthetic_path.glob("*.jsonl")):
        logger.info(f"Reading synthetic data from {jsonl_file}")
        with open(jsonl_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue

                input_text = item.get("input", "").strip()
                output_text = item.get("output", "").strip()
                if input_text and output_text:
                    pairs.append({
                        "input": input_text,
                        "output": output_text,
                        "source": item.get("source", "synthetic"),
                    })

    logger.info(f"Loaded {len(pairs)} synthetic pairs")
    return pairs


def generate_identity_pairs(corrections: list[dict], count: int) -> list[dict]:
    """Generate identity examples where input == output (correct transcriptions).

    These teach the model to not modify text that is already correct.
    """
    identity_pairs = []
    # Use corrected texts as identity pairs
    texts = list({p["output"] for p in corrections if p["output"]})
    random.shuffle(texts)

    for text in texts[:count]:
        identity_pairs.append({
            "input": text,
            "output": text,
            "source": "identity",
        })

    logger.info(f"Generated {len(identity_pairs)} identity pairs")
    return identity_pairs


def mix_and_deduplicate(
    corrections: list[dict],
    synthetic: list[dict],
    identity: list[dict],
    synthetic_ratio: float,
    max_pairs: int | None,
) -> list[dict]:
    """Mix data sources and deduplicate."""
    # Deduplicate by input text
    seen_inputs = set()
    unique = []

    for pair in corrections:
        key = pair["input"]
        if key not in seen_inputs:
            seen_inputs.add(key)
            unique.append(pair)
    corrections = unique

    # Calculate target counts
    total_human = len(corrections) + len(identity)
    if synthetic and synthetic_ratio > 0:
        target_synthetic = int(total_human * synthetic_ratio / (1 - synthetic_ratio))
        synthetic = synthetic[:target_synthetic]

    all_pairs = corrections + synthetic + identity

    if max_pairs and len(all_pairs) > max_pairs:
        random.shuffle(all_pairs)
        all_pairs = all_pairs[:max_pairs]

    random.shuffle(all_pairs)
    return all_pairs


def write_output(pairs: list[dict], output_dir: str):
    """Write training pairs to output JSONL."""
    os.makedirs(output_dir, exist_ok=True)
    output_file = os.path.join(output_dir, "train.jsonl")

    with open(output_file, "w") as f:
        for pair in pairs:
            record = {
                "input": pair["input"],
                "output": pair["output"],
            }
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    logger.info(f"Wrote {len(pairs)} pairs to {output_file}")


def report_statistics(pairs: list[dict]):
    """Print data statistics."""
    source_counts = Counter(p.get("source", "unknown") for p in pairs)
    total = len(pairs)

    logger.info("=" * 50)
    logger.info("Training Data Statistics")
    logger.info("=" * 50)
    logger.info(f"Total pairs: {total}")
    for source, count in sorted(source_counts.items()):
        pct = count / total * 100 if total > 0 else 0
        logger.info(f"  {source}: {count} ({pct:.1f}%)")

    # Input/output length stats
    input_lens = [len(p["input"]) for p in pairs]
    output_lens = [len(p["output"]) for p in pairs]
    if input_lens:
        logger.info(f"Input length:  avg={sum(input_lens)/len(input_lens):.0f}, "
                     f"min={min(input_lens)}, max={max(input_lens)}")
        logger.info(f"Output length: avg={sum(output_lens)/len(output_lens):.0f}, "
                     f"min={min(output_lens)}, max={max(output_lens)}")

    # Identity ratio
    identity_count = sum(1 for p in pairs if p["input"] == p["output"])
    logger.info(f"Identity pairs (input==output): {identity_count} ({identity_count/total*100:.1f}%)"
                if total > 0 else "Identity pairs: 0")
    logger.info("=" * 50)


def main():
    args = parse_args()
    random.seed(args.seed)

    # Load data sources
    corrections = load_corrections(args.corrections_dir, args.min_quality)

    synthetic = []
    if args.synthetic_dir:
        synthetic = load_synthetic(args.synthetic_dir)

    # Generate identity pairs
    identity_count = int(len(corrections) * args.identity_ratio)
    identity = generate_identity_pairs(corrections, identity_count)

    # Mix sources
    all_pairs = mix_and_deduplicate(
        corrections, synthetic, identity,
        args.synthetic_ratio, args.max_pairs,
    )

    if not all_pairs:
        logger.error("No training data generated")
        return

    # Report and write
    report_statistics(all_pairs)
    write_output(all_pairs, args.output)


if __name__ == "__main__":
    main()
