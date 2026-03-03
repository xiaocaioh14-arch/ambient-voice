# Correction Capture & Hotkey Optimization Plan

## Goal
Optimize the correction capture loop and hotkey handling for reliability.

## Hotkey Optimization
- Right Command push-to-talk with 200ms debounce
- pendingStop mechanism for early release during preparing state
- CGEvent tap on session event level

## Correction Capture Design
- After text injection, monitor user edits via AX API
- Detect submission signals (Enter / Cmd+Enter) per app profile
- Compare inserted text vs final text
- Quality scoring: similarity × latency × length ratio
- Only capture if quality above threshold

## App Profiles
Different apps have different editing patterns:
- Terminal: Cmd+Enter submits
- WeChat: Enter sends message
- Notes: auto-save, capture on focus change

## Data Flow
TextInjector → CorrectionCapture.startWindow → monitor edits → CorrectionStore.save
