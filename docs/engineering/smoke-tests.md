# WE Smoke Tests

## Quick Smoke (after each build)
1. [ ] Launch WE — menubar icon appears
2. [ ] Press Right Command — status changes to recording
3. [ ] Speak a sentence, release — text injected into focused app
4. [ ] Edit the injected text, press Enter — check ~/.we/corrections.jsonl for new entry
5. [ ] Check ~/.we/debug.log for WE:HotKey, WE:Voice, CorrectionCapture logs
6. [ ] Check ~/.we/voice-history.jsonl for session entry

## Model Download Smoke (fresh install)
1. [ ] Remove ~/.we/models/
2. [ ] Launch WE — setup window appears
3. [ ] Download completes — progress bar works
4. [ ] After download, voice input works normally

## Permission Smoke (fresh install)
1. [ ] Launch WE without Accessibility permission — guide appears
2. [ ] Grant permission — guide updates
3. [ ] Launch WE without Microphone permission — request dialog appears

## Polish Backend Smoke
1. [ ] With polish enabled (local) — text is polished before injection
2. [ ] With polish disabled — raw ASR text is injected
3. [ ] With backend unreachable — fallback to raw text (no hang)

## Regression Checks
1. [ ] Long speech (>30s) — no crash, text complete
2. [ ] Quick tap (<200ms) — no accidental trigger (debounce)
3. [ ] Switch apps during recording — text goes to original app
4. [ ] Multiple rapid recordings — no state machine corruption
