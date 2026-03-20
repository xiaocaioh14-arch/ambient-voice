#!/usr/bin/env python3
"""
Fine-tune Qwen3-0.6B with LoRA on WE correction data.

Prerequisites:
    pip install unsloth datasets trl

Usage (on 4090 server):
    # 1. Prepare data first
    python3 scripts/prepare_training_data.py --output train.jsonl

    # 2. Train
    python3 scripts/train_adapter.py

    # 3. Copy output to Mac
    scp we-adapter-q4_k_m.gguf mac:~/.we/models/we-adapter.gguf

Output: we-adapter-q4_k_m.gguf (ready for llama.cpp)
"""

import argparse
from pathlib import Path


def train(args):
    from unsloth import FastLanguageModel
    from datasets import load_dataset
    from trl import SFTTrainer
    from transformers import TrainingArguments

    print("Loading Qwen3-0.6B...")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name="Qwen/Qwen3-0.6B",
        max_seq_length=args.max_seq_length,
        load_in_4bit=True,
    )

    print("Adding LoRA adapter...")
    model = FastLanguageModel.get_peft_model(
        model,
        r=args.lora_rank,
        lora_alpha=args.lora_rank,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                         "gate_proj", "up_proj", "down_proj"],
        lora_dropout=0,
        use_gradient_checkpointing="unsloth",
    )

    print(f"Loading training data from {args.data}...")
    dataset = load_dataset("json", data_files=str(args.data), split="train")
    print(f"Training examples: {len(dataset)}")

    if len(dataset) < 50:
        print("WARNING: Very few training examples. Results may be poor.")
        print("Recommend at least 200-500 examples.")

    # Apply chat template
    def format_chat(example):
        return {"text": tokenizer.apply_chat_template(
            example["messages"], tokenize=False, add_generation_prompt=False
        )}

    dataset = dataset.map(format_chat)

    trainer = SFTTrainer(
        model=model,
        train_dataset=dataset,
        dataset_text_field="text",
        max_seq_length=args.max_seq_length,
        args=TrainingArguments(
            output_dir="./we-adapter-checkpoints",
            num_train_epochs=args.epochs,
            per_device_train_batch_size=args.batch_size,
            gradient_accumulation_steps=max(1, 8 // args.batch_size),
            learning_rate=args.lr,
            fp16=True,
            logging_steps=10,
            save_steps=100,
            warmup_ratio=0.1,
            weight_decay=0.01,
            seed=42,
        ),
    )

    print("Training...")
    stats = trainer.train()
    print(f"Training complete! Loss: {stats.training_loss:.4f}")

    # Save merged model
    print("Saving merged model...")
    merged_dir = Path("./we-merged")
    model.save_pretrained_merged(str(merged_dir), tokenizer, save_method="merged_16bit")

    print(f"Merged model saved to {merged_dir}")
    print(f"\nNext step: convert to GGUF")
    print(f"  python3 llama.cpp/convert_hf_to_gguf.py {merged_dir} "
          f"--outfile we-adapter-q4_k_m.gguf --outtype q4_k_m")
    print(f"\nThen copy to Mac:")
    print(f"  scp we-adapter-q4_k_m.gguf mac:~/.we/models/qwen3-0.6b.gguf")


def main():
    parser = argparse.ArgumentParser(description="Train LoRA adapter for WE voice correction")
    parser.add_argument("--data", type=Path, default="train.jsonl",
                        help="Training data path (from prepare_training_data.py)")
    parser.add_argument("--epochs", type=int, default=5,
                        help="Training epochs (default: 5, increase for small datasets)")
    parser.add_argument("--batch-size", type=int, default=4,
                        help="Batch size (default: 4)")
    parser.add_argument("--lr", type=float, default=2e-4,
                        help="Learning rate (default: 2e-4)")
    parser.add_argument("--lora-rank", type=int, default=16,
                        help="LoRA rank (default: 16)")
    parser.add_argument("--max-seq-length", type=int, default=256,
                        help="Max sequence length (default: 256)")
    args = parser.parse_args()

    if not args.data.exists():
        print(f"Training data not found: {args.data}")
        print(f"Run prepare_training_data.py first:")
        print(f"  python3 scripts/prepare_training_data.py --output {args.data}")
        return

    train(args)


if __name__ == "__main__":
    main()
