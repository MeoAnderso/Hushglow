#!/bin/bash
# Builds build/Hushglow.app from the Swift package.
#
# Signing decides whether Accessibility access survives a rebuild. macOS ties the permission
# to the app's signature: with a certificate the signature stays the same across builds;
# without one the app is ad-hoc signed and every rebuild looks like a different app.
# The certificate is taken from CODESIGN_IDENTITY, else one named "Hushglow Dev" if it
# exists in the keychain (see README, "Turning on the brightness and volume keys, and again
# after a rebuild").
#
# Every build runs with the hardened runtime, as a notarized one must. With a Developer ID
# certificate and NOTARY_PROFILE, the name of a keychain profile made with
# `xcrun notarytool store-credentials`, the app is also notarized and the ticket stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Hushglow Dev"'; then
    identity="Hushglow Dev"
fi
notary_profile="${NOTARY_PROFILE:-}"
# Only Developer ID signatures can be notarized; find that out before building.
if [ -n "$notary_profile" ] && [[ "$identity" != "Developer ID Application:"* ]]; then
    echo "NOTARY_PROFILE needs CODESIGN_IDENTITY to name a \"Developer ID Application: …\" certificate." >&2
    exit 64
fi

swift build -c release

app="build/Hushglow.app"
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Hushglow "$app/Contents/MacOS/Hushglow"
strip -x "$app/Contents/MacOS/Hushglow"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Sparkle, the updater, goes where a bundled framework belongs, and the executable is told to
# look for it there. Its XPC services are for sandboxed apps only, which this one is not, so
# they are left out rather than signed.
framework="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$framework"
rm -rf "$framework/Versions/B/XPCServices" "$framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/Hushglow"
# Sparkle's licence, with those of the code it includes, goes with every copy of it.
{
    echo "Hushglow includes Sparkle (https://sparkle-project.org), under the licence below."
    echo
    cat .build/artifacts/sparkle/Sparkle/LICENSE
} >"$app/Contents/Resources/Acknowledgements.txt"

# The text in other languages, from the string catalog: one folder per language it has been
# translated into. English is the code's own, and its folder says that the app has it.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$app/Contents/Resources"
mkdir -p "$app/Contents/Resources/en.lproj"

# The layered icon, which macOS renders with Liquid Glass, is compiled into an asset catalog.
min_os=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target "$min_os" \
    --output-partial-info-plist build/icon-info.plist --errors --warnings >/dev/null

# A secure timestamp is needed for notarization, and can only be had with a certificate.
timestamp="--timestamp=none"
[[ "$identity" == "Developer ID Application:"* ]] && timestamp="--timestamp"
# From the inside out, since signing a bundle does not sign the code inside it: Sparkle's
# helpers, then Sparkle, then the app. Everything carries the app's own signature, as library
# validation under the hardened runtime requires.
for part in "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
    codesign --force --options runtime "$timestamp" --sign "${identity:--}" "$part"
done
# Library validation lets the app load only code signed by the same team, and an ad-hoc or
# self-signed build has no team: without this, it could not load Sparkle at all. A Developer
# ID build keeps library validation.
entitlements=()
if [[ "$identity" != "Developer ID Application:"* ]]; then
    cat >build/entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
PLIST
    entitlements=(--entitlements build/entitlements.plist)
fi
codesign --force --options runtime "$timestamp" ${entitlements[@]+"${entitlements[@]}"} --sign "${identity:--}" \
    --identifier "$bundle_id" "$app"
codesign --verify --strict --deep "$app"

echo "Built $app ($(du -sh "$app" | cut -f1)), signed with: ${identity:-ad-hoc signature}"
if [ -z "$identity" ]; then
    echo "Ad-hoc signed: Accessibility access must be reset and granted again for this build."
    echo "  tccutil reset Accessibility $bundle_id"
fi

if [ -n "$notary_profile" ]; then
    archive="build/Hushglow-notarize.zip"
    ditto -c -k --keepParent "$app" "$archive"
    echo "Notarizing with the keychain profile \"$notary_profile\"; this can take a few minutes."
    result="build/notarization.json"
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait --output-format json >"$result"
    rm "$archive"
    # An upload that Apple turns down still ends the wait normally; the verdict is in the result.
    status=$(plutil -extract status raw -o - "$result")
    if [ "$status" != "Accepted" ]; then
        echo "Notarization ended as \"$status\". Apple's log of what it found:" >&2
        xcrun notarytool log "$(plutil -extract id raw -o - "$result")" --keychain-profile "$notary_profile" >&2
        exit 1
    fi
    xcrun stapler staple "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi
