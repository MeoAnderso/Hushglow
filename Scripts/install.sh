#!/bin/bash
# Builds Hushglow and installs it into /Applications, replacing a running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

target="/Applications/Hushglow.app"
staged="$target.new"

# Always install what the sources say, never a build left over from earlier.
Scripts/build-app.sh

# Copy next to the destination first, so a failed copy leaves the installed app untouched.
rm -rf "$staged"
ditto build/Hushglow.app "$staged"

# Stop the running copy so its key tap and shortcuts are released, and wait for it to exit:
# macOS refuses to start the new copy while the old one is still shutting down.
if pkill -x Hushglow 2>/dev/null; then
    while pgrep -x Hushglow >/dev/null; do sleep 0.2; done
fi
rm -rf "$target"
mv "$staged" "$target"
open "$target" || { sleep 2; open "$target"; }

echo "Installed $target"
