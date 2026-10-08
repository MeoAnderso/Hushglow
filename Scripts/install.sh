#!/bin/bash
# Installs build/DisplayKeys.app into /Applications and starts it.
# Run Scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

source="build/DisplayKeys.app"
target="/Applications/DisplayKeys.app"
[ -d "$source" ] || { echo "Run Scripts/build-app.sh first." >&2; exit 1; }

# Stop the running copy so its key tap and shortcuts are released before it is replaced.
pkill -x DisplayKeys 2>/dev/null || true
rm -rf "$target"
ditto "$source" "$target"
open "$target"

echo "Installed $target"
