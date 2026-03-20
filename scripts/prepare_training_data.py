#!/usr/bin/env python3
"""
Convert corrections.jsonl into ChatML training data for LoRA fine-tuning.

Usage:
    python3 scripts/prepare_training_data.py
    python3 scripts/prepare_training_data.py --min-quality 0.5 --output train.jsonl

Input:  ~/.we/corrections.jsonl (auto-collected by CorrectionCapture)
Output: train.jsonl (ChatML format for SFTTrainer)
"""

import json
import argparse
from pathlib import Path
from collections import Counter


SYSTEM_PROMPT = "纠正语音识别错误，只输出纠正结果。"

DEFAULT_INPUT = Path.home() / ".we" / "corrections.jsonl"
DEFAULT_OUTPUT = Path(__file__).parent / "train.jsonl"


def load_corrections(path: Path) -> list[dict]:
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def deduplicate(entries: list[dict]) -> list[dict]:
    """Keep only unique (insertedText, userFinalText) pairs."""
    seen = set()
    unique = []
    for e in entries:
        key = (e["insertedText"], e["userFinalText"])
        if key not in seen:
            seen.add(key)
            unique.append(e)
    return unique


def filter_entries(entries: list[dict], min_quality: float) -> list[dict]:
    """Filter out low-quality and unchanged entries."""
    filtered = []
    skipped = Counter()

    for e in entries:
        # Skip unchanged text
        if e["insertedText"] == e["userFinalText"]:
            skipped["unchanged"] += 1
            continue

        # Skip low quality (likely noise from keystroke capture bugs)
        if e.get("quality", 0) < min_quality:
            skipped["low_quality"] += 1
            continue

        # Skip if final text looks like garbage (keystroke reconstruction artifacts)
        final = e["userFinalText"]
        if any(c * 4 in final for c in set(final)):
            skipped["repetition"] += 1
            continue

        filtered.append(e)

    return filtered, skipped


def to_chatml(entries: list[dict]) -> list[dict]:
    """Convert to ChatML training format."""
    training_data = []
    for e in entries:
        training_data.append({
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": e["insertedText"]},
                {"role": "assistant", "content": e["userFinalText"]},
            ]
        })
    return training_data


def extract_word_pairs(entries: list[dict]) -> list[dict]:
    """Extract word-level correction pairs for analysis."""
    pairs = Counter()
    for e in entries:
        inserted = e["insertedText"]
        final = e["userFinalText"]
        # Simple character-level diff to find changed segments
        i, j = 0, 0
        while i < len(inserted) and j < len(final):
            if inserted[i] == final[j]:
                i += 1
                j += 1
            else:
                # Find the end of the different segment
                orig_start = i
                final_start = j
                # Scan forward to find next matching point
                found = False
                for look in range(1, 20):
                    if i + look < len(inserted) and j + look < len(final):
                        if inserted[i + look] == final[j + look]:
                            pairs[(inserted[orig_start:i + look], final[final_start:j + look])] += 1
                            i += look
                            j += look
                            found = True
                            break
                if not found:
                    # Rest of strings differ
                    pairs[(inserted[i:], final[j:])] += 1
                    break
    return pairs


def main():
    parser = argparse.ArgumentParser(description="Prepare LoRA training data from corrections")
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT,
                        help="Path to corrections.jsonl")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="Output path for training data")
    parser.add_argument("--min-quality", type=float, default=0.4,
                        help="Minimum quality score (default: 0.4)")
    parser.add_argument("--stats", action="store_true",
                        help="Print detailed statistics")
    args = parser.parse_args()

    # Load
    entries = load_corrections(args.input)
    print(f"Loaded: {len(entries)} entries from {args.input}")

    # Deduplicate
    entries = deduplicate(entries)
    print(f"After dedup: {len(entries)} unique pairs")

    # Filter
    entries, skipped = filter_entries(entries, args.min_quality)
    print(f"After filter (min_quality={args.min_quality}): {len(entries)} usable")
    for reason, count in skipped.items():
        print(f"  Skipped {count} ({reason})")

    # Stats
    if args.stats and entries:
        print(f"\nApp distribution:")
        apps = Counter(e["appName"] for e in entries)
        for app, count in apps.most_common():
            print(f"  {app}: {count}")

        print(f"\nTop word-level corrections:")
        pairs = extract_word_pairs(entries)
        for (orig, fixed), count in pairs.most_common(20):
            print(f"  \"{orig}\" -> \"{fixed}\" (x{count})")

    # Check readiness
    if len(entries) < 100:
        print(f"\n*** Data insufficient for training ({len(entries)}/500 minimum recommended) ***")
        print(f"*** Continue using WE to accumulate more corrections ***")

    # Convert and save
    training_data = to_chatml(entries)
    with open(args.output, "w") as f:
        for item in training_data:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(f"\nWrote {len(training_data)} training examples to {args.output}")


if __name__ == "__main__":
    main()
