#!/usr/bin/env python3
"""Route A: Whisper-large re-transcription for distillation training pairs.

Reads audio files from ~/.we/audio/, re-transcribes with Whisper-large,
and generates <SA_raw, Whisper_output> training pairs.

Supports:
- Local faster-whisper inference
- Remote Whisper-compatible endpoint

Output: distill_whisper.jsonl with fields:
  {sa_text, whisper_text, audio_path, source: "whisper"}
"""

import argparse
import json
import os
import sys
from pathlib import Path

import soundfile as sf
from tqdm import tqdm


def load_voice_history(we_dir: Path) -> list[dict]:
    """Load voice history entries that have audio files."""
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
            if entry.get("audio_file_path") and os.path.exists(entry["audio_file_path"]):
                entries.append(entry)
        except json.JSONDecodeError:
            continue
    return entries


def transcribe_local(audio_path: str, model_size: str = "large-v3") -> str:
    """Transcribe using local faster-whisper."""
    from faster_whisper import WhisperModel

    model = WhisperModel(model_size, device="auto", compute_type="auto")
    segments, _ = model.transcribe(audio_path, language="zh", beam_size=5)
    return "".join(seg.text for seg in segments)


def transcribe_remote(audio_path: str, endpoint: str) -> str:
    """Transcribe using a remote Whisper-compatible endpoint."""
    import openai

    client = openai.OpenAI(base_url=endpoint, api_key="unused")
    with open(audio_path, "rb") as f:
        result = client.audio.transcriptions.create(
            model="whisper-large-v3",
            file=f,
            language="zh",
        )
    return result.text


def main():
    parser = argparse.ArgumentParser(description="Generate Whisper distillation pairs")
    parser.add_argument("--we-dir", default=os.path.expanduser("~/.we"),
                        help="WE data directory (default: ~/.we)")
    parser.add_argument("--output", default="distill_whisper.jsonl",
                        help="Output JSONL file")
    parser.add_argument("--endpoint", default=None,
                        help="Remote Whisper endpoint URL (if not set, uses local faster-whisper)")
    parser.add_argument("--model-size", default="large-v3",
                        help="Whisper model size for local inference (default: large-v3)")
    args = parser.parse_args()

    we_dir = Path(args.we_dir)
    entries = load_voice_history(we_dir)

    if not entries:
        print("No voice history entries with audio files found.")
        sys.exit(0)

    print(f"Found {len(entries)} entries with audio")

    output_path = Path(args.output)
    pairs_written = 0

    with open(output_path, "w") as out:
        for entry in tqdm(entries, desc="Transcribing"):
            audio_path = entry["audio_file_path"]
            sa_text = entry.get("rawText", "")

            if not sa_text:
                continue

            try:
                if args.endpoint:
                    whisper_text = transcribe_remote(audio_path, args.endpoint)
                else:
                    whisper_text = transcribe_local(audio_path, args.model_size)
            except Exception as e:
                print(f"  Failed to transcribe {audio_path}: {e}", file=sys.stderr)
                continue

            if not whisper_text.strip():
                continue

            pair = {
                "sa_text": sa_text,
                "whisper_text": whisper_text.strip(),
                "audio_path": audio_path,
                "source": "whisper",
            }
            out.write(json.dumps(pair, ensure_ascii=False) + "\n")
            pairs_written += 1

    print(f"Wrote {pairs_written} training pairs to {output_path}")


if __name__ == "__main__":
    main()
