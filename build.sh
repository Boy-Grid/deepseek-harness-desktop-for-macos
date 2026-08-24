#!/bin/bash
# Assemble "DSH Desktop.app" from this repo's sources.
#
# Usage:
#   ./build.sh                      # rebuild the app at its default location
#   ./build.sh --output <app-path>  # build elsewhere (e.g. a throwaway dir)
#   ./build.sh --register           # also refresh LaunchServices + Spotlight
#   ./build.sh --release            # universal binary, Developer ID signature,
#                                   # hardened runtime and a secure timestamp --
#                                   # what notarization requires
#
# A default build is ad-hoc signed and compiled for this machine's architecture:
# fast, and enough to run locally.  --release is what ships.
#
# The app layout mirrors:
#   DSH Desktop.app/Contents/{Info.plist, MacOS/{LauncherAgent,launcher},
#   Resources/{icon.icns, README.md}}
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${OUTPUT:-$HOME/Applications/DSH Desktop.app}"
REGISTER=0
RELEASE=0
# Overridable so the script works for anyone with their own certificate; the
# prefix is enough as long as the keychain holds one Developer ID Application.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

while [ $# -gt 0 ]; do
    case "$1" in
        --register) REGISTER=1; shift ;;
        --release)  RELEASE=1; shift ;;
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Substring tests are written against a captured string rather than piped into
# `grep -q`.  Under `set -o pipefail` that pipe is a trap: grep -q exits at the
# first match, the writer gets SIGPIPE, and the pipeline reports failure for a
# search that actually succeeded.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

if [ "$RELEASE" -eq 1 ]; then
    if ! contains "$(security find-identity -v -p codesigning)" "$SIGN_IDENTITY"; then
        echo "--release needs a '$SIGN_IDENTITY' certificate in the keychain." >&2
        echo "Xcode → Settings → Accounts → your team → Manage Certificates → + " >&2
        exit 1
    fi
fi

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
AGENT="$APP/Contents/MacOS/LauncherAgent"

compile_slice() { # arch, output path
    xcrun swiftc -O -swift-version 5 -target "${1}-apple-macos${MIN_OS}" \
        -module-cache-path "$CACHE/${1}" \
        -framework AppKit -framework WebKit \
        -o "$2" "$REPO_DIR"/*.swift
}

if [ "$RELEASE" -eq 1 ]; then
    # A release has to run on Intel too: macOS 14 supports Macs going back to
    # 2018, and those users are exactly the ones least able to build from source.
    TMP_SLICES=$(mktemp -d)
    trap 'rm -rf "$TMP_SLICES"' EXIT
    slice_paths=()
    for arch in arm64 x86_64; do
        echo "compiling $arch"
        compile_slice "$arch" "$TMP_SLICES/$arch"
        slice_paths+=("$TMP_SLICES/$arch")
    done
    lipo -create -output "$AGENT" "${slice_paths[@]}"
else
    compile_slice "$(uname -m)" "$AGENT"
fi
chmod 755 "$AGENT"

# Every slice must carry the deployment target the plist advertises. Checking
# only the first would let a cross-compiled one drift unnoticed.
for arch in $(lipo -archs "$AGENT"); do
    built=$(vtool -arch "$arch" -show-build "$AGENT" | awk '/minos/ { print $2; exit }')
    if [ "$built" != "$MIN_OS" ]; then
        echo "deployment target drift: $arch says minos $built, Info.plist says $MIN_OS" >&2
        exit 1
    fi
done

# Signing order matters: the shell script must be signed FIRST, then the bundle
# (otherwise codesign rejects the unsigned script subcomponent in MacOS/).
#
# For a release, both get a secure timestamp, and the bundle gets the hardened
# runtime -- notarization rejects a submission without them. The script is not a
# Mach-O, so the runtime flag would be meaningless on it.
if [ "$RELEASE" -eq 1 ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/launcher"
    codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP/Contents/MacOS/launcher"
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ "$RELEASE" -eq 1 ]; then
    # Assert the three properties notarization checks, rather than trusting that
    # the flags above did what they say.
    info=$(codesign --display --verbose=4 "$APP" 2>&1)
    contains "$info" "(runtime)" \
        || { echo "hardened runtime missing on the bundle" >&2; exit 1; }
    contains "$info" "Timestamp=" \
        || { echo "secure timestamp missing on the bundle" >&2; exit 1; }
    contains "$info" "Authority=Developer ID Certification Authority" \
        || { echo "bundle is not signed by a Developer ID chain" >&2; exit 1; }
    echo "release signature: hardened runtime, timestamped, Developer ID"
fi

if [ "$REGISTER" -eq 1 ]; then
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    "$LSREGISTER" -f "$APP"
    mdimport -i "$APP"
fi

echo "built: $APP"
