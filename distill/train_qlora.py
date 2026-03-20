#!/usr/bin/env python3
"""QLoRA fine-tuning with sample weights for distillation training.

WeightedTrainer extends HuggingFace Trainer to support per-sample weights
from the merged training data. User corrections get 2x weight.

Usage:
  python train_qlora.py --data merged_training.jsonl --base-model Qwen/Qwen2.5-0.5B
"""

import argparse
import json
import os
import sys
from pathlib import Path

import torch
from datasets import Dataset
from peft import LoraConfig, TaskType, get_peft_model, prepare_model_for_kbit_training
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    Trainer,
    TrainingArguments,
)


def load_training_data(path: str) -> list[dict]:
    """Load merged training JSONL."""
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


class WeightedTrainer(Trainer):
    """Trainer that supports per-sample weights via a 'weight' column in the dataset."""

    def compute_loss(self, model, inputs, return_outputs=False, **kwargs):
        weights = inputs.pop("weight", None)
        outputs = model(**inputs)
        loss = outputs.loss

        if weights is not None:
            # Expand weights to match loss shape and compute weighted mean
            weights = weights.to(loss.device).float()
            loss = (loss * weights).mean() / weights.mean()

        return (loss, outputs) if return_outputs else loss


def tokenize_pair(tokenizer, input_text: str, output_text: str, max_length: int = 256):
    """Tokenize an input-output pair for causal LM training.

    Format: <|im_start|>system\n口语转书面。只输出结果。<|im_end|>\n<|im_start|>user\n{input}<|im_end|>\n<|im_start|>assistant\n{output}<|im_end|>
    """
    prompt = f"<|im_start|>system\n口语转书面。只输出结果。<|im_end|>\n<|im_start|>user\n{input_text}<|im_end|>\n<|im_start|>assistant\n"
    full = prompt + output_text + "<|im_end|>"

    tokenized = tokenizer(full, truncation=True, max_length=max_length,
                           padding="max_length", return_tensors=None)

    # Mask prompt tokens in labels (only train on output)
    prompt_tokens = tokenizer(prompt, truncation=True, max_length=max_length,
                               return_tensors=None)
    prompt_len = len(prompt_tokens["input_ids"])

    labels = tokenized["input_ids"].copy()
    labels[:prompt_len] = [-100] * prompt_len

    tokenized["labels"] = labels
    return tokenized


def main():
    parser = argparse.ArgumentParser(description="QLoRA fine-tuning with weighted samples")
    parser.add_argument("--data", required=True, help="Merged training JSONL path")
    parser.add_argument("--base-model", default="Qwen/Qwen2.5-0.5B",
                        help="Base model name or path")
    parser.add_argument("--output-dir", default="./qlora-output",
                        help="Output directory for adapter weights")
    parser.add_argument("--lora-r", type=int, default=16, help="LoRA rank")
    parser.add_argument("--lora-alpha", type=int, default=32, help="LoRA alpha")
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--gradient-accumulation", type=int, default=4)
    args = parser.parse_args()

    # Load data
    raw_data = load_training_data(args.data)
    if not raw_data:
        print("No training data found.")
        sys.exit(1)
    print(f"Loaded {len(raw_data)} training pairs")

    # Load tokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.base_model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # Tokenize
    tokenized_data = []
    for entry in raw_data:
        tok = tokenize_pair(tokenizer, entry["input"], entry["output"], args.max_length)
        tok["weight"] = entry.get("weight", 1.0)
        tokenized_data.append(tok)

    dataset = Dataset.from_list(tokenized_data)
    dataset.set_format("torch")

    print(f"Dataset: {len(dataset)} samples")
    weights = [e.get("weight", 1.0) for e in raw_data]
    print(f"Weight distribution: min={min(weights)}, max={max(weights)}, "
          f"mean={sum(weights)/len(weights):.2f}")

    # 4-bit quantization config
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )

    # Load model
    model = AutoModelForCausalLM.from_pretrained(
        args.base_model,
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
    )
    model = prepare_model_for_kbit_training(model)

    # LoRA config
    lora_config = LoraConfig(
        task_type=TaskType.CAUSAL_LM,
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj",
                        "gate_proj", "up_proj", "down_proj"],
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # Training args
    training_args = TrainingArguments(
        output_dir=args.output_dir,
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.gradient_accumulation,
        learning_rate=args.lr,
        warmup_ratio=0.1,
        logging_steps=10,
        save_strategy="epoch",
        bf16=True,
        optim="paged_adamw_8bit",
        report_to="none",
        remove_unused_columns=False,  # Keep 'weight' column
    )

    # Train
    trainer = WeightedTrainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        tokenizer=tokenizer,
    )
    trainer.train()

    # Save adapter
    model.save_pretrained(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)
    print(f"\nAdapter saved to {args.output_dir}")


if __name__ == "__main__":
    main()
