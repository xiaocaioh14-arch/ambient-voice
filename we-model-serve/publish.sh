#!/bin/bash
# Publish new model version: update symlinks, compute hashes, update manifest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MANIFEST="manifest.json"

echo "Publishing model files..."

# Compute SHA256 and file sizes for all model files
update_manifest() {
    local key="$1"
    local file="$2"

    if [ ! -f "$file" ]; then
        echo "Warning: $file not found, skipping"
        return
    fi

    local sha256
    sha256=$(shasum -a 256 "$file" | awk '{print $1}')
    local size
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)

    echo "  $key: $file ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes"))"
    echo "    sha256: $sha256"

    # Update manifest using python for reliable JSON manipulation
    python3 -c "
import json, sys
with open('$MANIFEST') as f:
    m = json.load(f)
m['models']['$key']['file'] = '$file'
m['models']['$key']['sha256'] = '$sha256'
m['models']['$key']['size'] = $size
with open('$MANIFEST', 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
"
}

# Update timestamp
python3 -c "
import json
from datetime import datetime, timezone
with open('$MANIFEST') as f:
    m = json.load(f)
m['updated_at'] = datetime.now(timezone.utc).isoformat()
with open('$MANIFEST', 'w') as f:
    json.dump(m, f, indent=2)
    f.write('\n')
"

# Update each model entry
update_manifest "base" "qwen3-0.6b.gguf"
update_manifest "adapter" "sa-adapter.gguf"

echo ""
echo "Manifest updated:"
cat "$MANIFEST"
echo ""
echo "Done. Server will serve updated manifest at /manifest.json"
