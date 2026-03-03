# SA Adapter Training Pipeline

Train an ASR correction adapter from user correction data.

## Overview

- **Model**: Qwen3-0.6B base + QLoRA adapter
- **Purpose**: Fix ASR transcription errors using learned correction patterns
- **Principle**: 不确定时不改 (when uncertain, don't change)

## Pipeline

```
corrections.jsonl → gen_training_data_v3.py → train_qlora_0.6b.py → eval_0.6b.py → merge_lora.py → deploy
```

1. **Collect** corrections from `~/.we/corrections.jsonl` on client machines
2. **Generate** training data with `gen_training_data_v3.py` (mix human + synthetic)
3. **Train** QLoRA adapter with `train_qlora_0.6b.py` (4-bit quantized, r=16)
4. **Evaluate** with `eval_0.6b.py` (must pass break_rate threshold)
5. **Merge & Convert** with `merge_lora.py` (output GGUF for on-device inference)
6. **Deploy** to `we-model-serve` for client download

## Quick Start

```bash
# Full pipeline
./scripts/retrain.sh

# Individual steps
python gen_training_data_v3.py --corrections_dir /path/to/corrections --output train_v3/
python train_qlora_0.6b.py --data_dir train_v3/ --output_dir checkpoints-0.6b-v7 --epochs 3
python eval_0.6b.py --model_path merged-0.6b-v7/ --test_data test_set.jsonl
python merge_lora.py --base_model Qwen/Qwen3-0.6B --lora_path checkpoints-0.6b-v7/ --output merged-0.6b-v7/
```

## Data Format

Training JSONL (`train_v3/*.jsonl`):
```json
{"input": "ASR raw transcription", "output": "corrected text"}
```

## Requirements

```bash
pip install -r requirements.txt
```

Requires CUDA GPU (tested on RTX 4090).
