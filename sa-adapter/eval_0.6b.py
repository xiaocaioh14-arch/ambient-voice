#!/usr/bin/env python3
"""Evaluate 0.6B ASR correction model.

Metrics:
- fix_rate: percentage of errors correctly fixed
- break_rate: percentage of correct text incorrectly modified
- net_score: fix_rate - break_rate
- CER: Character Error Rate change

Key principle: 不确定时不改 (when uncertain, don't change)

Usage:
    python eval_0.6b.py --model_path merged-0.6b-v7/ --test_data test_set.jsonl
    python eval_0.6b.py --model_path merged-0.6b-v7/ --test_data test_set.jsonl --output eval_results.json
"""

import argparse
import json
import logging
import sys
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

SYSTEM_PROMPT = "口语转书面。只输出结果。"


def parse_args():
    parser = argparse.ArgumentParser(description="Evaluate 0.6B ASR correction model")
    parser.add_argument("--model_path", type=str, required=True, help="Path to merged model")
    parser.add_argument("--test_data", type=str, required=True, help="Test JSONL file")
    parser.add_argument("--output", type=str, default=None, help="Output JSON results file")
    parser.add_argument("--max_new_tokens", type=int, default=256)
    parser.add_argument("--batch_size", type=int, default=1)
    parser.add_argument("--device", type=str, default="auto")
    return parser.parse_args()


def load_test_data(path: str) -> list[dict]:
    """Load test set from JSONL."""
    items = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            items.append(item)
    logger.info(f"Loaded {len(items)} test examples")
    return items


def compute_cer(reference: str, hypothesis: str) -> float:
    """Compute Character Error Rate using edit distance."""
    if not reference:
        return 0.0 if not hypothesis else 1.0

    ref_chars = list(reference)
    hyp_chars = list(hypothesis)
    n = len(ref_chars)
    m = len(hyp_chars)

    # Dynamic programming edit distance
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dp[i][0] = i
    for j in range(m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if ref_chars[i - 1] == hyp_chars[j - 1] else 1
            dp[i][j] = min(
                dp[i - 1][j] + 1,      # deletion
                dp[i][j - 1] + 1,      # insertion
                dp[i - 1][j - 1] + cost,  # substitution
            )

    return dp[n][m] / n


def run_inference(model, tokenizer, input_text: str, max_new_tokens: int) -> str:
    """Run model inference on a single input."""
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": input_text},
    ]
    prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = tokenizer(prompt, return_tensors="pt").to(model.device)

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_new_tokens,
            do_sample=False,
            temperature=1.0,
            top_p=1.0,
        )

    # Decode only new tokens
    new_tokens = outputs[0][inputs["input_ids"].shape[1]:]
    result = tokenizer.decode(new_tokens, skip_special_tokens=True).strip()
    return result


def evaluate(model, tokenizer, test_data: list[dict], max_new_tokens: int) -> dict:
    """Run evaluation and compute metrics."""
    results = []
    error_cases = []  # Cases where ASR had errors (input != expected)
    correct_cases = []  # Cases where ASR was correct (input == expected)

    for i, item in enumerate(test_data):
        input_text = item["input"]
        expected = item["output"]

        prediction = run_inference(model, tokenizer, input_text, max_new_tokens)

        is_error_case = input_text != expected
        is_identity = input_text == expected

        result = {
            "input": input_text,
            "expected": expected,
            "prediction": prediction,
            "is_error_case": is_error_case,
            "correct": prediction == expected,
        }
        results.append(result)

        if is_error_case:
            error_cases.append(result)
        if is_identity:
            correct_cases.append(result)

        if (i + 1) % 50 == 0:
            logger.info(f"Evaluated {i + 1}/{len(test_data)}")

    # Compute metrics
    # fix_rate: how many error cases did we fix correctly?
    fixes = sum(1 for r in error_cases if r["correct"])
    fix_rate = fixes / len(error_cases) if error_cases else 0.0

    # break_rate: how many correct cases did we break?
    breaks = sum(1 for r in correct_cases if not r["correct"])
    break_rate = breaks / len(correct_cases) if correct_cases else 0.0

    net_score = fix_rate - break_rate

    # CER: compare model output vs expected, and baseline (no correction) vs expected
    model_cer_total = 0.0
    baseline_cer_total = 0.0
    for r in results:
        model_cer_total += compute_cer(r["expected"], r["prediction"])
        baseline_cer_total += compute_cer(r["expected"], r["input"])
    n = len(results)
    model_cer = model_cer_total / n if n > 0 else 0.0
    baseline_cer = baseline_cer_total / n if n > 0 else 0.0

    metrics = {
        "total_examples": len(results),
        "error_cases": len(error_cases),
        "correct_cases": len(correct_cases),
        "fix_rate": round(fix_rate, 4),
        "break_rate": round(break_rate, 4),
        "net_score": round(net_score, 4),
        "model_cer": round(model_cer, 4),
        "baseline_cer": round(baseline_cer, 4),
        "cer_improvement": round(baseline_cer - model_cer, 4),
    }

    return metrics, results


def print_markdown_summary(metrics: dict):
    """Print evaluation results as markdown."""
    print("\n## Evaluation Results\n")
    print(f"| Metric | Value |")
    print(f"|--------|-------|")
    print(f"| Total examples | {metrics['total_examples']} |")
    print(f"| Error cases | {metrics['error_cases']} |")
    print(f"| Correct cases | {metrics['correct_cases']} |")
    print(f"| **Fix rate** | **{metrics['fix_rate']:.1%}** |")
    print(f"| **Break rate** | **{metrics['break_rate']:.1%}** |")
    print(f"| **Net score** | **{metrics['net_score']:.1%}** |")
    print(f"| Model CER | {metrics['model_cer']:.4f} |")
    print(f"| Baseline CER | {metrics['baseline_cer']:.4f} |")
    print(f"| CER improvement | {metrics['cer_improvement']:.4f} |")

    # Quality gate
    print(f"\n### Quality Gate")
    if metrics['break_rate'] > 0.05:
        print(f"FAIL: break_rate {metrics['break_rate']:.1%} > 5% threshold")
    elif metrics['net_score'] < 0.10:
        print(f"WARN: net_score {metrics['net_score']:.1%} < 10% threshold")
    else:
        print(f"PASS: break_rate={metrics['break_rate']:.1%}, net_score={metrics['net_score']:.1%}")


def main():
    args = parse_args()

    # Load model
    logger.info(f"Loading model from {args.model_path}")
    tokenizer = AutoTokenizer.from_pretrained(args.model_path, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        args.model_path,
        device_map=args.device,
        torch_dtype=torch.bfloat16,
        trust_remote_code=True,
    )
    model.eval()

    # Load test data
    test_data = load_test_data(args.test_data)

    # Evaluate
    metrics, results = evaluate(model, tokenizer, test_data, args.max_new_tokens)

    # Output
    print_markdown_summary(metrics)

    if args.output:
        output_data = {
            "metrics": metrics,
            "results": results,
        }
        with open(args.output, "w") as f:
            json.dump(output_data, f, ensure_ascii=False, indent=2)
        logger.info(f"Saved detailed results to {args.output}")

    # Exit with error if quality gate fails
    if metrics["break_rate"] > 0.05:
        logger.error("Quality gate FAILED: break_rate too high")
        sys.exit(1)


if __name__ == "__main__":
    main()
