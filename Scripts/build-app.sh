#!/bin/bash
# Builds build/DisplayKeys.app from the Swift package.
#
# Signing decides whether Accessibility access survives a rebuild. macOS ties the permission
# to the app's signature: with a certificate the signature stays the same across builds;
# without one the app is ad-hoc signed and every rebuild looks like a different app.
# The certificate is taken from CODESIGN_IDENTITY, else one named "DisplayKeys Dev" if it
# exists in the keychain (see README, "Keeping the permission across rebuilds").
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="build/DisplayKeys.app"
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/DisplayKeys "$app/Contents/MacOS/DisplayKeys"
strip -x "$app/Contents/MacOS/DisplayKeys"
cp Resources/Info.plist "$app/Contents/Info.plist"

# The layered icon, which macOS 26 and later render with Liquid Glass, is compiled into an
# asset catalog. The flat icon is copied afterwards and serves earlier versions of macOS.
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist build/icon-info.plist --errors --warnings >/dev/null
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"DisplayKeys Dev"'; then
    identity="DisplayKeys Dev"
fi
codesign --force --sign "${identity:--}" --identifier "$bundle_id" "$app"

echo "Built $app ($(du -sh "$app" | cut -f1)), signed with: ${identity:-ad-hoc signature}"
if [ -z "$identity" ]; then
    echo "Ad-hoc signed: Accessibility access must be reset and granted again for this build."
    echo "  tccutil reset Accessibility $bundle_id"
fi
