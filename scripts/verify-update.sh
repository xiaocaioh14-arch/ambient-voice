#!/bin/bash
# Post-release verification
set -euo pipefail

echo "=== WE Post-Release Verification ==="

# Check app launches
echo "→ Checking app binary..."
if [ -f ".build/release/WE" ]; then
    echo "  ✓ Binary exists"
else
    echo "  ✗ Binary not found"
    exit 1
fi

# Check data directory
echo "→ Checking data directory..."
if [ -d "$HOME/.we" ]; then
    echo "  ✓ ~/.we exists"
    ls -lh ~/.we/*.jsonl 2>/dev/null || echo "  (no data files yet)"
else
    echo "  ℹ ~/.we not yet created (first launch needed)"
fi

# Check debug log
echo "→ Checking debug log..."
if [ -f "$HOME/.we/debug.log" ]; then
    tail -5 ~/.we/debug.log
else
    echo "  ℹ No debug log yet"
fi

echo "=== Verification complete ==="
