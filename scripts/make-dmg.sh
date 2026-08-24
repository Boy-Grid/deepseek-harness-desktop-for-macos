#!/bin/bash
# Package a release build into a notarized, stapled disk image.
#
# Usage:
#   scripts/make-dmg.sh                       # build --release, then package
#   scripts/make-dmg.sh --app <path>          # package an existing release build
#   scripts/make-dmg.sh --skip-notarize       # signed dmg only (offline / dry run)
#
# Output goes to dist/: the .dmg plus a SHA256SUMS line for it.
#
# Notarization needs credentials in the keychain. Create them once with:
#   xcrun notarytool store-credentials "dsh-desktop-notary" \
#     --key <AuthKey_XXXX.p8> --key-id <Key ID> --issuer <Issuer ID>
# Only Team Keys work for notarization; an Individual Key returns 401.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTARY_PROFILE="${NOTARY_PROFILE:-dsh-desktop-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARIZE_TIMEOUT="${NOTARIZE_TIMEOUT:-1800}"   # seconds to wait for a verdict
SPCTL=$(command -v spctl 2>/dev/null || true)
[ -n "$SPCTL" ] || SPCTL=/usr/sbin/spctl
APP=""
NOTARIZE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --skip-notarize) NOTARIZE=0; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

DIST="$REPO_DIR/dist"
mkdir -p "$DIST"

if [ -z "$APP" ]; then
    APP="$DIST/DSH Desktop.app"
    rm -rf "$APP"
    "$REPO_DIR/build.sh" --release --output "$APP"
fi
[ -d "$APP" ] || { echo "no app bundle at $APP" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$DIST/DSH-Desktop-${VERSION}-universal.dmg"

# Refuse to ship something that is only ad-hoc signed: the dmg would look
# official and Gatekeeper would still reject the app inside it.
# Two things to get right here:
#   --verbose=4, because the default verbosity prints only the leaf authority and
#   the certificate chain checked for below would never appear;
#   and a captured string instead of `| grep -q`, because under `set -o pipefail`
#   grep -q exits at the first match, the writer gets SIGPIPE, and the pipeline
#   reports failure for a search that succeeded.
signature_info=$(codesign --display --verbose=4 "$APP" 2>&1)
case "$signature_info" in
    *"Authority=Developer ID Certification Authority"*) ;;
    *)
        echo "$APP is not signed with a Developer ID -- build it with --release" >&2
        exit 1
        ;;
esac

# --- stage: the app plus the drag-to-install target ------------------------
# The bundle is staged under its *product* name, not whatever the source path
# happens to be called. Copying it as-is means a build at /tmp/whatever.app ends
# up in the image as "whatever.app", and that is the name the user drags into
# Applications.
BUNDLE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP/Contents/Info.plist")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/${BUNDLE_NAME}.app"
ln -s /Applications "$STAGE/Applications"

echo "creating $DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "DSH Desktop $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"

# The disk image is signed too, so a tampered download fails before it is even
# mounted rather than at first launch.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

if [ "$NOTARIZE" -eq 1 ]; then
    echo "submitting for notarization"
    # Deliberately not `submit --wait`: that call has been seen to hang long after
    # Apple already accepted the submission, and it leaves no way to resume --
    # the id it would have printed is gone with it. Submit, capture the id, then
    # poll with a bound.
    submit_out=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" 2>&1)
    printf '%s\n' "$submit_out"
    SUBMISSION_ID=$(printf '%s' "$submit_out" | awk '/^ *id:/ { print $2; exit }')
    [ -n "$SUBMISSION_ID" ] || { echo "could not read a submission id" >&2; exit 1; }

    status=""
    waited=0
    while [ "$waited" -lt "$NOTARIZE_TIMEOUT" ]; do
        info=$(xcrun notarytool info "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1)
        status=$(printf '%s' "$info" | awk '/^ *status:/ { $1=""; sub(/^ */, ""); print; exit }')
        case "$status" in
            Accepted|Invalid|Rejected) break ;;
        esac
        sleep 15
        waited=$((waited + 15))
    done

    if [ "$status" != "Accepted" ]; then
        echo "notarization did not succeed (status: ${status:-unknown})" >&2
        echo "submission id: $SUBMISSION_ID" >&2
        echo "details:  xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
        echo "resume:   xcrun stapler staple '$DMG'   # once it reads Accepted" >&2
        exit 1
    fi
    echo "notarization: Accepted (${SUBMISSION_ID})"

    # Stapling writes the ticket into the image, so Gatekeeper can approve it
    # without asking Apple -- which is what makes an offline first launch work.
    xcrun stapler staple "$DMG"

    echo "--- verification ---"
    # Absolute path: spctl lives in /usr/sbin, which a stripped PATH may not carry.
    "$SPCTL" --assess --type open --context context:primary-signature -v "$DMG"
    # And check the app inside, under the name a user will actually install.
    # `head -1` would close the pipe early and hand the writer a SIGPIPE, which
    # pipefail then reports as failure. `tail -1` consumes all of the input, and
    # the volume name is taken whole because it contains spaces.
    attach_out=$(hdiutil attach -nobrowse -readonly "$DMG")
    mount_point=$(printf '%s\n' "$attach_out" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)
    if [ -n "$mount_point" ]; then
        "$SPCTL" --assess --type execute -v "$mount_point/${BUNDLE_NAME}.app" || true
        xcrun stapler validate "$mount_point/${BUNDLE_NAME}.app" || true
        hdiutil detach "$mount_point" -quiet
    fi
fi

cd "$DIST"
shasum -a 256 "$(basename "$DMG")" | tee "SHA256SUMS"

echo
echo "built: $DMG"
[ "$NOTARIZE" -eq 1 ] || echo "note: not notarized (--skip-notarize)"
