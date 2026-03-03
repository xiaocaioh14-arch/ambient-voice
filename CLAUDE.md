# WE Project - AI Coding Instructions

## Project Overview
WE is a macOS menubar voice input app — a private AI OS entry point.
Core value chain: Apple SpeechAnalyzer → 0.6B correction model → user correction flywheel.

## Build & Run
```
make build   # Build llama.cpp + Swift
make run     # Run WE
make test    # Run tests
```

## Architecture
- Shell + Module pattern: WEApp is shell, VoiceModule is first module
- Voice pipeline: HotKey → Record → SA Transcribe → L1 Swap → L2 Polish → Inject → Capture
- Config at ~/.we/config.json, runtime config at ~/.we/runtime-config.json

## Key Files
- Sources/VoiceSession.swift - Recording + SA transcription
- Sources/VoicePipeline.swift - Post-processing orchestration
- Sources/PolishClient.swift - Backend routing (local/ollama/openai)
- Sources/CorrectionCapture.swift - User correction monitoring
- Sources/ModelManager.swift - Model download and verification

## Conventions
- Endpoints in config, not hardcoded
- Use MagicDNS names (*.ts.andy.qzz.io), never raw IPs
- Log with DebugLog categories: WE:HotKey, WE:Voice, WE:Pipeline, etc.
- Data files in ~/.we/ as JSONL format

## Testing
- `swift test` for unit tests
- `docs/engineering/smoke-tests.md` for manual smoke tests
- Always test with real voice input after changes
