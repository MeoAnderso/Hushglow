#!/bin/bash
# Brings Resources/Localizable.xcstrings in line with the text in the code, as Xcode does when it
# builds: every string the code looks up becomes an entry, and one the code no longer uses is
# marked stale. The compiler finds them, rather than a search of the text, so that each entry has
# the placeholders the app looks it up with, such as %lld for a whole number.
set -euo pipefail
cd "$(dirname "$0")/.."

found=build/strings
rm -rf "$found" build/strings-build
mkdir -p "$found"
# A build of its own, so that the flags do not throw away the usual build's products, and from
# scratch, since a file that is not compiled again lists none of its strings.
swift build --scratch-path build/strings-build -Xswiftc -emit-localized-strings \
    -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$found"
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$found"/*.stringsdata
echo "Resources/Localizable.xcstrings: $(xcrun xcstringstool print Resources/Localizable.xcstrings | wc -l | tr -d ' ') strings"
