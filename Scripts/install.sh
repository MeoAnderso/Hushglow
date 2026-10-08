#!/bin/bash
# Installs build/DisplayKeys.app into /Applications and starts it.
# Run Scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

source="build/DisplayKeys.app"
target="/Applications/DisplayKeys.app"
[ -d "$source" ] || { echo "Run Scripts/build-app.sh first." >&2; exit 1; }

# Stop the running copy so its key tap and shortcuts are released, and wait for it to exit:
# macOS refuses to start the new copy while the old one is still shutting down.
if pkill -x DisplayKeys 2>/dev/null; then
    while pgrep -x DisplayKeys >/dev/null; do sleep 0.2; done
fi
rm -rf "$target"
ditto "$source" "$target"
open "$target" || { sleep 2; open "$target"; }

echo "Installed $target"
