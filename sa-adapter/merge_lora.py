#!/usr/bin/env python3
"""Merge LoRA adapter and convert to GGUF.

Usage:
    # Merge LoRA into base model
    python merge_lora.py --base_model Qwen/Qwen3-0.6B --lora_path checkpoints-0.6b-v7/final --output merged-0.6b-v7/

    # Convert merged model to GGUF
    python merge_lora.py --convert_gguf --input merged-0.6b-v7/ --output qwen3-0.6b-q4_k_m.gguf --quant q4_k_m

    # Export LoRA adapter as standalone GGUF
    python merge_lora.py --export_lora_gguf --lora_path checkpoints-0.6b-v7/final --output sa-adapter.gguf
"""

import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path

import torch
from peft import PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

LLAMA_CPP_CONVERT = os.environ.get("LLAMA_CPP_CONVERT", "llama-cpp-convert")
LLAMA_CPP_QUANTIZE = os.environ.get("LLAMA_CPP_QUANTIZE", "llama-quantize")

QUANT_TYPES = ["q4_k_m", "q8_0", "f16", "q4_0", "q5_k_m"]


def parse_args():
    parser = argparse.ArgumentParser(description="Merge LoRA and convert to GGUF")
    subparsers = parser.add_subparsers(dest="command")

    # Default: merge mode (also via flags)
    parser.add_argument("--base_model", type=str, default="Qwen/Qwen3-0.6B")
    parser.add_argument("--lora_path", type=str, help="Path to LoRA adapter checkpoint")
    parser.add_argument("--output", type=str, help="Output path")
    parser.add_argument("--input", type=str, help="Input merged model path (for GGUF conversion)")

    # Mode flags
    parser.add_argument("--convert_gguf", action="store_true", help="Convert merged model to GGUF")
    parser.add_argument("--export_lora_gguf", action="store_true", help="Export LoRA adapter as GGUF")
    parser.add_argument("--quant", type=str, default="q4_k_m",
                        choices=QUANT_TYPES, help="Quantization type for GGUF")
    parser.add_argument("--llama_cpp_path", type=str, default=None,
                        help="Path to llama.cpp directory")

    return parser.parse_args()


def merge_lora(base_model: str, lora_path: str, output: str):
    """Merge LoRA adapter weights into base model."""
    logger.info(f"Loading base model: {base_model}")
    model = AutoModelForCausalLM.from_pretrained(
        base_model,
        torch_dtype=torch.float16,
        device_map="cpu",
        trust_remote_code=True,
    )
    tokenizer = AutoTokenizer.from_pretrained(base_model, trust_remote_code=True)

    logger.info(f"Loading LoRA adapter: {lora_path}")
    model = PeftModel.from_pretrained(model, lora_path)

    logger.info("Merging LoRA weights...")
    model = model.merge_and_unload()

    logger.info(f"Saving merged model to {output}")
    os.makedirs(output, exist_ok=True)
    model.save_pretrained(output)
    tokenizer.save_pretrained(output)
    logger.info("Merge complete")


def find_convert_script(llama_cpp_path: str | None) -> str:
    """Find llama.cpp convert script."""
    if llama_cpp_path:
        convert_py = os.path.join(llama_cpp_path, "convert_hf_to_gguf.py")
        if os.path.exists(convert_py):
            return convert_py

    # Try common locations
    candidates = [
        os.path.expanduser("~/llama.cpp/convert_hf_to_gguf.py"),
        "/opt/llama.cpp/convert_hf_to_gguf.py",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path

    logger.error("Could not find llama.cpp convert_hf_to_gguf.py")
    logger.error("Set --llama_cpp_path or LLAMA_CPP_CONVERT environment variable")
    sys.exit(1)


def find_quantize_binary(llama_cpp_path: str | None) -> str:
    """Find llama.cpp quantize binary."""
    if llama_cpp_path:
        binary = os.path.join(llama_cpp_path, "build", "bin", "llama-quantize")
        if os.path.exists(binary):
            return binary

    # Try PATH
    import shutil
    binary = shutil.which("llama-quantize")
    if binary:
        return binary

    candidates = [
        os.path.expanduser("~/llama.cpp/build/bin/llama-quantize"),
        "/opt/llama.cpp/build/bin/llama-quantize",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path

    logger.error("Could not find llama-quantize binary")
    sys.exit(1)


def convert_to_gguf(input_path: str, output_path: str, quant: str, llama_cpp_path: str | None):
    """Convert HuggingFace model to GGUF format."""
    convert_script = find_convert_script(llama_cpp_path)

    # Step 1: Convert to f16 GGUF
    f16_path = output_path.replace(".gguf", "-f16.gguf")
    logger.info(f"Converting to f16 GGUF: {f16_path}")

    cmd = [sys.executable, convert_script, input_path, "--outfile", f16_path, "--outtype", "f16"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"Conversion failed: {result.stderr}")
        sys.exit(1)

    if quant == "f16":
        os.rename(f16_path, output_path)
        logger.info(f"Saved f16 GGUF to {output_path}")
        return

    # Step 2: Quantize
    quantize_binary = find_quantize_binary(llama_cpp_path)
    logger.info(f"Quantizing to {quant}: {output_path}")

    cmd = [quantize_binary, f16_path, output_path, quant]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"Quantization failed: {result.stderr}")
        sys.exit(1)

    # Clean up f16 intermediate
    if os.path.exists(f16_path):
        os.remove(f16_path)

    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    logger.info(f"Saved {quant} GGUF to {output_path} ({size_mb:.1f} MB)")


def export_lora_gguf(lora_path: str, output_path: str, llama_cpp_path: str | None):
    """Export LoRA adapter as standalone GGUF."""
    convert_script_dir = Path(find_convert_script(llama_cpp_path)).parent
    lora_convert = convert_script_dir / "convert_lora_to_gguf.py"

    if not lora_convert.exists():
        logger.error(f"LoRA convert script not found: {lora_convert}")
        sys.exit(1)

    logger.info(f"Converting LoRA adapter to GGUF: {output_path}")
    cmd = [sys.executable, str(lora_convert), lora_path, "--outfile", output_path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        logger.error(f"LoRA GGUF conversion failed: {result.stderr}")
        sys.exit(1)

    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    logger.info(f"Saved LoRA GGUF to {output_path} ({size_mb:.1f} MB)")


def main():
    args = parse_args()

    if args.convert_gguf:
        if not args.input or not args.output:
            logger.error("--convert_gguf requires --input and --output")
            sys.exit(1)
        convert_to_gguf(args.input, args.output, args.quant, args.llama_cpp_path)

    elif args.export_lora_gguf:
        if not args.lora_path or not args.output:
            logger.error("--export_lora_gguf requires --lora_path and --output")
            sys.exit(1)
        export_lora_gguf(args.lora_path, args.output, args.llama_cpp_path)

    else:
        # Default: merge mode
        if not args.lora_path or not args.output:
            logger.error("Merge mode requires --lora_path and --output")
            sys.exit(1)
        merge_lora(args.base_model, args.lora_path, args.output)


if __name__ == "__main__":
    main()
