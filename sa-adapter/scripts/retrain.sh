#!/bin/bash
# Full retrain pipeline: sync → generate → train → eval → convert → deploy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SA_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(dirname "$SA_DIR")"
SERVE_DIR="$PROJECT_DIR/we-model-serve"

# Configuration
VERSION="${VERSION:-v7}"
BASE_MODEL="${BASE_MODEL:-Qwen/Qwen3-0.6B}"
CORRECTIONS_DIR="${CORRECTIONS_DIR:-$HOME/.we/corrections}"
TRAIN_DIR="$SA_DIR/train_v3"
CHECKPOINT_DIR="$SA_DIR/checkpoints-0.6b-$VERSION"
MERGED_DIR="$SA_DIR/merged-0.6b-$VERSION"
GGUF_OUTPUT="$SA_DIR/qwen3-0.6b-q4_k_m.gguf"
ADAPTER_GGUF="$SA_DIR/sa-adapter.gguf"
EPOCHS="${EPOCHS:-3}"
BREAK_RATE_THRESHOLD="${BREAK_RATE_THRESHOLD:-0.05}"

echo "========================================"
echo "SA Adapter Retrain Pipeline"
echo "Version: $VERSION"
echo "========================================"

# Step 1: Sync corrections from client machines
echo ""
echo "[Step 1/7] Syncing corrections..."
if [ -d "$CORRECTIONS_DIR" ]; then
    echo "Using local corrections from $CORRECTIONS_DIR"
else
    echo "Warning: corrections directory not found at $CORRECTIONS_DIR"
    echo "Create it or set CORRECTIONS_DIR environment variable"
    exit 1
fi

# Step 2: Generate training data
echo ""
echo "[Step 2/7] Generating training data..."
python "$SA_DIR/gen_training_data_v3.py" \
    --corrections_dir "$CORRECTIONS_DIR" \
    --output "$TRAIN_DIR"

TRAIN_COUNT=$(wc -l < "$TRAIN_DIR/train.jsonl" | tr -d ' ')
echo "Generated $TRAIN_COUNT training pairs"

if [ "$TRAIN_COUNT" -lt 100 ]; then
    echo "Warning: fewer than 100 training pairs, results may be poor"
fi

# Step 3: Train QLoRA
echo ""
echo "[Step 3/7] Training QLoRA adapter..."
python "$SA_DIR/train_qlora_0.6b.py" \
    --base_model "$BASE_MODEL" \
    --data_dir "$TRAIN_DIR" \
    --output_dir "$CHECKPOINT_DIR" \
    --epochs "$EPOCHS"

echo "Training complete: $CHECKPOINT_DIR"

# Step 4: Merge LoRA
echo ""
echo "[Step 4/7] Merging LoRA weights..."
python "$SA_DIR/merge_lora.py" \
    --base_model "$BASE_MODEL" \
    --lora_path "$CHECKPOINT_DIR/final" \
    --output "$MERGED_DIR"

# Step 5: Evaluate
echo ""
echo "[Step 5/7] Evaluating model..."
TEST_DATA="$SA_DIR/test_set.jsonl"
if [ ! -f "$TEST_DATA" ]; then
    echo "Warning: test set not found at $TEST_DATA, skipping evaluation"
else
    EVAL_OUTPUT="$SA_DIR/eval_results_$VERSION.json"
    python "$SA_DIR/eval_0.6b.py" \
        --model_path "$MERGED_DIR" \
        --test_data "$TEST_DATA" \
        --output "$EVAL_OUTPUT"
    echo "Evaluation passed"
fi

# Step 6: Convert to GGUF
echo ""
echo "[Step 6/7] Converting to GGUF..."
python "$SA_DIR/merge_lora.py" \
    --convert_gguf \
    --input "$MERGED_DIR" \
    --output "$GGUF_OUTPUT" \
    --quant q4_k_m

# Also export standalone adapter GGUF
python "$SA_DIR/merge_lora.py" \
    --export_lora_gguf \
    --lora_path "$CHECKPOINT_DIR/final" \
    --output "$ADAPTER_GGUF"

echo "GGUF files ready:"
ls -lh "$GGUF_OUTPUT" "$ADAPTER_GGUF"

# Step 7: Deploy to we-model-serve
echo ""
echo "[Step 7/7] Deploying to model server..."
if [ -d "$SERVE_DIR" ]; then
    # Update symlinks
    ln -sf "$GGUF_OUTPUT" "$SERVE_DIR/qwen3-0.6b.gguf"
    ln -sf "$ADAPTER_GGUF" "$SERVE_DIR/sa-adapter.gguf"

    # Update manifest
    if [ -f "$SERVE_DIR/publish.sh" ]; then
        bash "$SERVE_DIR/publish.sh"
    fi
    echo "Deployed to $SERVE_DIR"
else
    echo "Warning: serve directory not found at $SERVE_DIR"
fi

echo ""
echo "========================================"
echo "Pipeline complete!"
echo "Model: $GGUF_OUTPUT"
echo "Adapter: $ADAPTER_GGUF"
echo "========================================"
