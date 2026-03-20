#!/usr/bin/env python3
"""Route B: Gemini/LLM correction for distillation training pairs.

Sends SA raw text to Gemini (or OpenAI-compatible endpoint) for correction,
generating <SA_raw, Gemini_corrected> training pairs.

Output: distill_gemini.jsonl with fields:
  {sa_text, corrected_text, source: "gemini"}
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

from tqdm import tqdm

SYSTEM_PROMPT = """你是语音识别纠错专家。用户给你一段语音识别的原始文本（可能包含同音错字、漏字、多字等问题），
请纠正为正确的书面中文。只输出纠正后的文本，不要解释。如果原文没有错误，原样输出。"""


def load_voice_history(we_dir: Path) -> list[dict]:
    """Load voice history entries."""
    history_path = we_dir / "voice-history.jsonl"
    if not history_path.exists():
        return []

    entries = []
    for line in history_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get("rawText"):
                entries.append(entry)
        except json.JSONDecodeError:
            continue
    return entries


def correct_openai_compatible(text: str, endpoint: str, api_key: str,
                               model: str = "gemini-2.0-flash") -> str:
    """Send text to an OpenAI-compatible endpoint for correction."""
    import openai

    client = openai.OpenAI(base_url=endpoint, api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text},
        ],
        temperature=0,
        max_tokens=512,
    )
    return response.choices[0].message.content.strip()


def main():
    parser = argparse.ArgumentParser(description="Generate Gemini distillation pairs")
    parser.add_argument("--we-dir", default=os.path.expanduser("~/.we"),
                        help="WE data directory (default: ~/.we)")
    parser.add_argument("--output", default="distill_gemini.jsonl",
                        help="Output JSONL file")
    parser.add_argument("--endpoint", default="https://generativelanguage.googleapis.com/v1beta/openai",
                        help="Gemini/OpenAI-compatible endpoint")
    parser.add_argument("--api-key", default=None,
                        help="API key (or set GEMINI_API_KEY env var)")
    parser.add_argument("--model", default="gemini-2.0-flash",
                        help="Model name (default: gemini-2.0-flash)")
    parser.add_argument("--rate-limit", type=float, default=0.5,
                        help="Seconds between requests (default: 0.5)")
    parser.add_argument("--max-retries", type=int, default=3,
                        help="Max retries per request (default: 3)")
    args = parser.parse_args()

    api_key = args.api_key or os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        print("Error: --api-key or GEMINI_API_KEY env var required", file=sys.stderr)
        sys.exit(1)

    we_dir = Path(args.we_dir)
    entries = load_voice_history(we_dir)

    if not entries:
        print("No voice history entries found.")
        sys.exit(0)

    print(f"Found {len(entries)} entries")

    output_path = Path(args.output)
    pairs_written = 0

    with open(output_path, "w") as out:
        for entry in tqdm(entries, desc="Correcting"):
            sa_text = entry["rawText"]
            if not sa_text.strip():
                continue

            corrected = None
            for attempt in range(args.max_retries):
                try:
                    corrected = correct_openai_compatible(
                        sa_text, args.endpoint, api_key, args.model
                    )
                    break
                except Exception as e:
                    if attempt < args.max_retries - 1:
                        wait = (attempt + 1) * 2
                        print(f"  Retry {attempt + 1} for '{sa_text[:30]}...': {e}", file=sys.stderr)
                        time.sleep(wait)
                    else:
                        print(f"  Failed after {args.max_retries} retries: {e}", file=sys.stderr)

            if not corrected:
                continue

            pair = {
                "sa_text": sa_text,
                "corrected_text": corrected,
                "source": "gemini",
            }
            out.write(json.dumps(pair, ensure_ascii=False) + "\n")
            pairs_written += 1

            time.sleep(args.rate_limit)

    print(f"Wrote {pairs_written} training pairs to {output_path}")


if __name__ == "__main__":
    main()
