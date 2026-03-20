#!/usr/bin/env python3
"""Merge distillation pairs from Whisper, Gemini, and user corrections.

Combines:
- distill_whisper.jsonl (Route A)
- distill_gemini.jsonl (Route B)
- ~/.we/corrections.jsonl (user corrections)

Weighting scheme (from ambient-voice design):
  人工纠错 x2 > 双路一致 x1.5 > 单路 x1

Output: merged_training.jsonl with fields:
  {input, output, weight, source}
"""

import argparse
import json
import os
import sys
from pathlib import Path


def load_jsonl(path: Path) -> list[dict]:
    """Load a JSONL file, skipping bad lines."""
    if not path.exists():
        return []
    entries = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def main():
    parser = argparse.ArgumentParser(description="Merge distillation training pairs")
    parser.add_argument("--whisper", default="distill_whisper.jsonl",
                        help="Whisper pairs JSONL")
    parser.add_argument("--gemini", default="distill_gemini.jsonl",
                        help="Gemini pairs JSONL")
    parser.add_argument("--corrections", default=os.path.expanduser("~/.we/corrections.jsonl"),
                        help="User corrections JSONL")
    parser.add_argument("--output", default="merged_training.jsonl",
                        help="Output merged JSONL")
    parser.add_argument("--correction-weight", type=float, default=2.0,
                        help="Weight for user correction pairs (default: 2.0)")
    parser.add_argument("--dual-agree-weight", type=float, default=1.5,
                        help="Weight when Whisper and Gemini agree (default: 1.5)")
    parser.add_argument("--single-weight", type=float, default=1.0,
                        help="Weight for single-route pairs (default: 1.0)")
    args = parser.parse_args()

    # Load all routes
    whisper_pairs = load_jsonl(Path(args.whisper))
    gemini_pairs = load_jsonl(Path(args.gemini))
    corrections = load_jsonl(Path(args.corrections))

    # Build lookup: sa_text -> whisper_output
    whisper_map: dict[str, str] = {}
    for pair in whisper_pairs:
        sa = pair.get("sa_text", "").strip()
        whisper = pair.get("whisper_text", "").strip()
        if sa and whisper and sa != whisper:
            whisper_map[sa] = whisper

    # Build lookup: sa_text -> gemini_output
    gemini_map: dict[str, str] = {}
    for pair in gemini_pairs:
        sa = pair.get("sa_text", "").strip()
        corrected = pair.get("corrected_text", "").strip()
        if sa and corrected and sa != corrected:
            gemini_map[sa] = corrected

    output_entries = []

    # Find all unique SA texts from both routes
    all_sa_texts = set(whisper_map.keys()) | set(gemini_map.keys())

    dual_agree_count = 0
    for sa in all_sa_texts:
        w = whisper_map.get(sa)
        g = gemini_map.get(sa)

        if w and g and w == g:
            # Both routes agree — higher weight
            output_entries.append({
                "input": sa,
                "output": w,
                "weight": args.dual_agree_weight,
                "source": "dual-agree",
            })
            dual_agree_count += 1
        else:
            # Single-route pairs
            if w:
                output_entries.append({
                    "input": sa,
                    "output": w,
                    "weight": args.single_weight,
                    "source": "whisper",
                })
            if g:
                output_entries.append({
                    "input": sa,
                    "output": g,
                    "weight": args.single_weight,
                    "source": "gemini",
                })

    print(f"Whisper pairs: {len(whisper_map)} valid")
    print(f"Gemini pairs: {len(gemini_map)} valid")
    print(f"Dual-agree pairs: {dual_agree_count} (weight={args.dual_agree_weight})")

    # User corrections (highest weight)
    correction_count = 0
    for entry in corrections:
        raw = entry.get("rawText", "").strip()
        user_final = entry.get("userFinalText", "").strip()

        if raw and user_final and raw != user_final:
            output_entries.append({
                "input": raw,
                "output": user_final,
                "weight": args.correction_weight,
                "source": "correction",
            })
            correction_count += 1
    print(f"User corrections: {correction_count} valid (weight={args.correction_weight})")

    # Deduplicate by (input, output), keeping highest weight
    seen: dict[tuple[str, str], int] = {}
    deduped = []
    for entry in output_entries:
        key = (entry["input"], entry["output"])
        if key not in seen:
            seen[key] = len(deduped)
            deduped.append(entry)
        else:
            idx = seen[key]
            if entry["weight"] > deduped[idx]["weight"]:
                deduped[idx] = entry

    output_path = Path(args.output)
    with open(output_path, "w") as f:
        for entry in deduped:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(f"\nTotal: {len(deduped)} unique training pairs written to {output_path}")
    by_source: dict[str, int] = {}
    for e in deduped:
        by_source[e["source"]] = by_source.get(e["source"], 0) + 1
    for src, count in sorted(by_source.items()):
        print(f"  {src}: {count}")

    # Weight distribution
    weights = [e["weight"] for e in deduped]
    if weights:
        print(f"\nWeight distribution: min={min(weights)}, max={max(weights)}, "
              f"mean={sum(weights)/len(weights):.2f}")


if __name__ == "__main__":
    main()
