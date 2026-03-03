# Speech Bench

ASR benchmarking toolkit for comparing transcription configurations and post-processing strategies.

## Tools

- **bench.py** - A/B benchmark runner for ASR configurations
- **param_test.py** - Parameter matrix testing for SpeechAnalyzer

## Usage

```bash
# Run benchmark comparison
python bench.py --config configs/baseline.json --config configs/with_adapter.json --audio_dir test_audio/

# Run parameter matrix test
python param_test.py --audio_dir test_audio/ --output results/
```

## Key Findings

- 纠错优先场景不建议 fastResults (fast results not recommended for correction-priority scenarios)
- See PARAM_TEST_REPORT.md for detailed parameter tuning results
- See RESULTS.md for overall benchmark comparisons

## Results

Benchmark results are stored in `results/`.
