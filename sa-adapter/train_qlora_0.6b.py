#!/usr/bin/env python3
"""QLoRA fine-tuning for Qwen3-0.6B ASR correction model.

Usage:
    python train_qlora_0.6b.py --data_dir train_v3/ --output_dir checkpoints-0.6b-v7 --epochs 3
    python train_qlora_0.6b.py --data_dir train_v3/ --output_dir checkpoints-0.6b-v7 --epochs 3 --resume
"""

import argparse
import json
import logging
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
    TrainingArguments,
    Trainer,
    DataCollatorForSeq2Seq,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

SYSTEM_PROMPT = "口语转书面。只输出结果。"
BASE_MODEL = "Qwen/Qwen3-0.6B"
MAX_SEQ_LEN = 512


def parse_args():
    parser = argparse.ArgumentParser(description="QLoRA fine-tuning for Qwen3-0.6B")
    parser.add_argument("--base_model", type=str, default=BASE_MODEL)
    parser.add_argument("--data_dir", type=str, required=True, help="Directory containing training JSONL files")
    parser.add_argument("--output_dir", type=str, required=True, help="Output checkpoint directory")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch_size", type=int, default=4)
    parser.add_argument("--gradient_accumulation_steps", type=int, default=8)
    parser.add_argument("--learning_rate", type=float, default=2e-4)
    parser.add_argument("--max_seq_len", type=int, default=MAX_SEQ_LEN)
    parser.add_argument("--lora_r", type=int, default=16)
    parser.add_argument("--lora_alpha", type=int, default=32)
    parser.add_argument("--lora_dropout", type=float, default=0.05)
    parser.add_argument("--resume", action="store_true", help="Resume from latest checkpoint")
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def load_training_data(data_dir: str) -> list[dict]:
    """Load training pairs from JSONL files in data_dir."""
    pairs = []
    data_path = Path(data_dir)
    for jsonl_file in sorted(data_path.glob("*.jsonl")):
        logger.info(f"Loading {jsonl_file}")
        with open(jsonl_file) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                item = json.loads(line)
                if "input" in item and "output" in item:
                    pairs.append(item)
    logger.info(f"Loaded {len(pairs)} training pairs from {data_dir}")
    return pairs


def format_chat_messages(input_text: str, output_text: str) -> list[dict]:
    """Format a training pair as chat messages."""
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": input_text},
        {"role": "assistant", "content": output_text},
    ]


def preprocess_dataset(pairs: list[dict], tokenizer) -> Dataset:
    """Tokenize training pairs into a HuggingFace Dataset."""
    input_ids_list = []
    labels_list = []

    for pair in pairs:
        messages = format_chat_messages(pair["input"], pair["output"])
        # Tokenize full conversation
        full_text = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
        full_ids = tokenizer(full_text, truncation=True, max_length=MAX_SEQ_LEN)["input_ids"]

        # Tokenize without assistant response to find prefix length
        prompt_messages = messages[:-1]
        prompt_text = tokenizer.apply_chat_template(prompt_messages, tokenize=False, add_generation_prompt=True)
        prompt_ids = tokenizer(prompt_text, truncation=True, max_length=MAX_SEQ_LEN)["input_ids"]

        # Labels: mask prompt tokens with -100, only train on assistant output
        labels = [-100] * len(prompt_ids) + full_ids[len(prompt_ids):]
        assert len(labels) == len(full_ids)

        input_ids_list.append(full_ids)
        labels_list.append(labels)

    return Dataset.from_dict({
        "input_ids": input_ids_list,
        "labels": labels_list,
    })


def main():
    args = parse_args()
    torch.manual_seed(args.seed)

    logger.info(f"Base model: {args.base_model}")
    logger.info(f"Data dir: {args.data_dir}")
    logger.info(f"Output dir: {args.output_dir}")

    # 4-bit quantization config
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
        bnb_4bit_use_double_quant=True,
    )

    # Load tokenizer
    tokenizer = AutoTokenizer.from_pretrained(args.base_model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    # Load model with quantization
    logger.info("Loading model with 4-bit quantization...")
    model = AutoModelForCausalLM.from_pretrained(
        args.base_model,
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
        torch_dtype=torch.bfloat16,
    )
    model = prepare_model_for_kbit_training(model)

    # LoRA config
    lora_config = LoraConfig(
        task_type=TaskType.CAUSAL_LM,
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        target_modules=[
            "q_proj", "v_proj", "k_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
        bias="none",
    )

    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # Load and preprocess data
    pairs = load_training_data(args.data_dir)
    if not pairs:
        logger.error("No training data found")
        sys.exit(1)

    dataset = preprocess_dataset(pairs, tokenizer)
    logger.info(f"Dataset size: {len(dataset)}")

    # Training arguments
    training_args = TrainingArguments(
        output_dir=args.output_dir,
        num_train_epochs=args.epochs,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        weight_decay=0.01,
        warmup_ratio=0.03,
        lr_scheduler_type="cosine",
        logging_steps=10,
        save_strategy="epoch",
        save_total_limit=3,
        bf16=True,
        gradient_checkpointing=True,
        report_to="none",
        seed=args.seed,
        optim="paged_adamw_8bit",
    )

    # Data collator
    data_collator = DataCollatorForSeq2Seq(
        tokenizer=tokenizer,
        padding=True,
        return_tensors="pt",
    )

    # Trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=dataset,
        data_collator=data_collator,
    )

    # Train
    resume_from = None
    if args.resume:
        checkpoints = sorted(Path(args.output_dir).glob("checkpoint-*"))
        if checkpoints:
            resume_from = str(checkpoints[-1])
            logger.info(f"Resuming from {resume_from}")
        else:
            logger.warning("No checkpoint found, training from scratch")

    logger.info("Starting training...")
    trainer.train(resume_from_checkpoint=resume_from)

    # Save final adapter
    final_path = os.path.join(args.output_dir, "final")
    model.save_pretrained(final_path)
    tokenizer.save_pretrained(final_path)
    logger.info(f"Saved final adapter to {final_path}")

    # Log training summary
    metrics = trainer.state.log_history
    if metrics:
        last_loss = next(
            (m["loss"] for m in reversed(metrics) if "loss" in m),
            None,
        )
        logger.info(f"Final training loss: {last_loss}")


if __name__ == "__main__":
    main()
