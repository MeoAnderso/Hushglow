#!/bin/bash
# Makes a release the app can update itself to: builds the app, packs it, signs the archive
# with the Sparkle key and writes the feed that points at it, all in build/. With --publish it
# then creates the release on GitHub; the feed address in Info.plist names the latest one.
#
# The signing key is the one Sparkle's generate_keys keeps in the login keychain, whose public
# half must be SUPublicEDKey in Resources/Info.plist. SPARKLE_KEY_FILE names a file holding a
# private key instead, for trying the script out. CODESIGN_IDENTITY and NOTARY_PROFILE are
# passed on to build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

publish=false
case "${1:-}" in
    "") ;;
    --publish) publish=true ;;
    *) echo "Usage: Scripts/release.sh [--publish]" >&2; exit 64 ;;
esac

info=Resources/Info.plist
read_info() { /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true; }
version=$(read_info CFBundleShortVersionString)
build=$(read_info CFBundleVersion)
minimum=$(read_info LSMinimumSystemVersion)
feed=$(read_info SUFeedURL)
public_key=$(read_info SUPublicEDKey)
repository=$(sed -E -n 's#^https://github\.com/([^/]+/[^/]+)/releases/latest/download/appcast\.xml$#\1#p' <<<"$feed")
tag="v$version"
tools=.build/artifacts/sparkle/Sparkle/bin

if [ -z "$public_key" ]; then
    echo "Resources/Info.plist has no SUPublicEDKey, so the app would not take this update. Create the" >&2
    echo "key once with $tools/generate_keys and put the public key it prints in Info.plist." >&2
    exit 64
fi
if [ -z "$repository" ]; then
    echo "SUFeedURL in Resources/Info.plist is not a GitHub repository's latest release." >&2
    exit 64
fi

key_file=()
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then
    key_file=(--ed-key-file "$SPARKLE_KEY_FILE")
elif [ "$("$tools/generate_keys" -p)" != "$public_key" ]; then
    # The app checks every update against the key it was built with; another key's signature
    # would make this update one it turns down.
    echo "The key in the keychain is not the one in Resources/Info.plist." >&2
    exit 1
fi

if $publish; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "Commit or set aside the changes first: a release is made from a commit." >&2
        exit 1
    fi
    if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
        echo "$repository already has a release $tag; raise the version in Resources/Info.plist." >&2
        exit 1
    fi
fi

Scripts/build-app.sh

archive="build/Hushglow-$version.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent build/Hushglow.app "$archive"
# The signature and length attributes of the feed's enclosure, as Sparkle writes them.
enclosure=$("$tools/sign_update" ${key_file[@]+"${key_file[@]}"} "$archive")

cat >build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Hushglow</title>
        <link>https://github.com/$repository</link>
        <item>
            <title>Hushglow $version</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
            <link>https://github.com/$repository/releases/tag/$tag</link>
            <enclosure url="https://github.com/$repository/releases/download/$tag/Hushglow-$version.zip"
                type="application/octet-stream" $enclosure />
        </item>
    </channel>
</rss>
XML
xmllint --noout build/appcast.xml
echo "Prepared $archive and build/appcast.xml for $tag (build $build)."

if $publish; then
    gh release create "$tag" "$archive" build/appcast.xml --repo "$repository" \
        --target "$(git rev-parse HEAD)" --title "Hushglow $version" --generate-notes
    echo "Published https://github.com/$repository/releases/tag/$tag"
else
    echo "Run Scripts/release.sh --publish to create the release on GitHub."
fi
