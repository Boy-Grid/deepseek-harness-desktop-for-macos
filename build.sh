#!/bin/bash
# Assemble "DSH Desktop.app" from this repo's sources.
#
# Usage:
#   ./build.sh                      # rebuild the app at its default location
#   ./build.sh --output <app-path>  # build elsewhere (e.g. a throwaway dir)
#   ./build.sh --register           # also refresh LaunchServices + Spotlight
#
# The app layout mirrors:
#   DSH Desktop.app/Contents/{Info.plist, MacOS/{LauncherAgent,launcher},
#   Resources/{icon.icns, README.md}}
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${OUTPUT:-$HOME/Applications/DSH Desktop.app}"
REGISTER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --register) REGISTER=1; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

APP="$OUTPUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$REPO_DIR/launcher"             "$APP/Contents/MacOS/launcher"
cp "$REPO_DIR/Info.plist"           "$APP/Contents/Info.plist"
cp "$REPO_DIR/icon.icns"            "$APP/Contents/Resources/icon.icns"
cp "$REPO_DIR/Resources-README.md"  "$APP/Contents/Resources/README.md"
chmod 755 "$APP/Contents/MacOS/launcher"
chmod 644 "$APP/Contents/Info.plist" "$APP/Contents/Resources/"*

# Compile the native agent (module cache stays in the repo, gitignored).
#
# A precompiled module records the absolute path it was built under, so a cache
# carried along by a repo rename/move fails the build with an opaque "missing
# required module 'SwiftShims'".  Stamp the cache with its own path and wipe it
# when that no longer matches.
CACHE="$REPO_DIR/.build-cache"
STAMP="$CACHE/.repo-path"
if [ -d "$CACHE" ] && [ "$(cat "$STAMP" 2>/dev/null)" != "$REPO_DIR" ]; then
    echo "module cache was built elsewhere — clearing $CACHE"
    rm -rf "$CACHE"
fi
mkdir -p "$CACHE"
printf '%s' "$REPO_DIR" > "$STAMP"

# The deployment target comes from Info.plist so the two cannot disagree.
# Without an explicit -target, swiftc stamps the *host's* OS version into the
# binary: a build on macOS 26 refuses to launch on anything older, however
# generous LSMinimumSystemVersion looks.  Measured before this was fixed:
# minos 26.0 against a plist advertising 12.0.
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$REPO_DIR/Info.plist")
TARGET="$(uname -m)-apple-macos${MIN_OS}"

xcrun swiftc -O -swift-version 5 -target "$TARGET" -module-cache-path "$CACHE" \
    -framework AppKit -framework WebKit \
    -o "$APP/Contents/MacOS/LauncherAgent" "$REPO_DIR"/*.swift
chmod 755 "$APP/Contents/MacOS/LauncherAgent"

BUILT_MIN=$(vtool -show-build "$APP/Contents/MacOS/LauncherAgent" | awk '/minos/ { print $2; exit }')
if [ "$BUILT_MIN" != "$MIN_OS" ]; then
    echo "deployment target drift: binary says minos $BUILT_MIN, Info.plist says $MIN_OS" >&2
    exit 1
fi

# Signing order matters: the shell script must be signed FIRST, then the bundle
# (otherwise codesign rejects the unsigned script subcomponent in MacOS/).
codesign --force --sign - "$APP/Contents/MacOS/launcher"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

if [ "$REGISTER" -eq 1 ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP"
    mdimport -i "$APP"
fi

echo "built: $APP"
