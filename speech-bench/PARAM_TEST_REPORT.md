# Parameter Test Report

## Test Date
_YYYY-MM-DD_

## Test Setup
- Audio samples: _N_ files from test corpus
- Reference: manually verified transcriptions

## Parameters Tested

| Parameter | Values |
|-----------|--------|
| taskHint | .dictation, .search, .unspecified |
| shouldReportPartialResults | true, false |
| customizedLanguageModel | none, custom |

## Results

| Config | Avg CER | Avg Latency | P95 Latency | Confidence | Final Change Rate |
|--------|---------|-------------|-------------|------------|-------------------|
| _fill in after test_ | | | | | |

## Key Findings

1. **纠错优先场景不建议 fastResults**: Using `shouldReportPartialResults=true` introduces text instability between partial and final results. When the correction model processes partial text that later changes, it produces suboptimal corrections.

2. **taskHint=.dictation** generally yields better results for longer-form input typical of voice typing.

3. **customizedLanguageModel** improves domain-specific vocabulary recognition but does not help with general text.

## Recommendations

- For correction pipeline: `taskHint=.dictation`, `shouldReportPartialResults=false`
- For real-time display: `taskHint=.dictation`, `shouldReportPartialResults=true` (accept lower correction quality)
