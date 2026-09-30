#!/bin/zsh
# Explicit distribution action: signs a copy and uploads that copy to Apple.
# Credentials must already exist in Keychain; this script never accepts passwords.
set -euo pipefail
umask 077
if [[ "$#" != 2 ]]; then
  print -u2 "Usage: script/notarize.sh DEVELOPER_ID_CERTIFICATE_SHA1 NOTARY_KEYCHAIN_PROFILE"
  print -u2 "Run script/build.sh first. This command uploads a signed copy to Apple; it does not publish to GitHub."
  exit 2
fi
SIGNING_CERTIFICATE="$1"
NOTARY_PROFILE="$2"
if [[ ! "$SIGNING_CERTIFICATE" =~ '^[[:xdigit:]]{40}$' || -z "$NOTARY_PROFILE" ]]; then
  print -u2 "Supply the 40-character SHA-1 of an installed Developer ID Application identity and a nonempty Keychain profile name. Never pass a password."
  exit 2
fi
IDENTITY_COUNT="$(security find-identity -v -p codesigning | awk -v certificate="$SIGNING_CERTIFICATE" 'toupper($2) == toupper(certificate) && /"Developer ID Application:/ { count++ } END { print count+0 }')"
if [[ "$IDENTITY_COUNT" != 1 ]]; then
  print -u2 "The specified Developer ID Application identity is not available with a valid private key in your keychain. Install your signing identity using Xcode or Keychain Access, then retry. Nothing was signed or uploaded."
  exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$HOME/Library/Caches/DriveExplorerBuild"
SOURCE_APP="$BUILD_DIR/DriveExplorer.app"
"$PROJECT_DIR/script/verify_bundle.sh" "$SOURCE_APP"
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
RELEASE_DIR="$(mktemp -d "$BUILD_DIR/notarization.XXXXXX")"
trap 'print -u2 "Distribution preparation stopped. Local artifacts and diagnostics remain in $RELEASE_DIR; no release was published."' ZERR
APP_DIR="$RELEASE_DIR/DriveExplorer.app"
ditto --norsrc --noextattr "$SOURCE_APP" "$APP_DIR"
xattr -cr "$APP_DIR"
# The only executable is the main binary; the SwiftPM bundle contains resources.
codesign --force --sign "$SIGNING_CERTIFICATE" --options runtime --timestamp "$APP_DIR"
"$PROJECT_DIR/script/verify_bundle.sh" "$APP_DIR"
codesign --verify --strict --all-architectures -R '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP_DIR"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$RELEASE_DIR/submission.zip"
print "Submitting the signed app to Apple. Private diagnostics stay in $RELEASE_DIR."
if ! xcrun notarytool submit "$RELEASE_DIR/submission.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$RELEASE_DIR/submission.json"; then
  print -u2 "Apple submission failed or timed out. Inspect $RELEASE_DIR/submission.json and the error above; a timed-out submission may still be processing. No final archive was created."
  exit 1
fi
NOTARY_STATUS="$(plutil -extract status raw -o - "$RELEASE_DIR/submission.json")"
if [[ "$NOTARY_STATUS" != Accepted ]]; then
  print -u2 "Apple returned notarization status $NOTARY_STATUS. Inspect $RELEASE_DIR/submission.json and retrieve the submission log with notarytool. No final archive was created."
  exit 1
fi
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"
spctl --assess --type execute --verbose=2 "$APP_DIR"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$RELEASE_DIR/DriveExplorer.zip"
ditto -x -k "$RELEASE_DIR/DriveExplorer.zip" "$RELEASE_DIR/extracted"
"$PROJECT_DIR/script/verify_bundle.sh" "$RELEASE_DIR/extracted/DriveExplorer.app"
xcrun stapler validate "$RELEASE_DIR/extracted/DriveExplorer.app"
spctl --assess --type execute --verbose=2 "$RELEASE_DIR/extracted/DriveExplorer.app"
(cd "$RELEASE_DIR" && shasum -a 256 DriveExplorer.zip > SHA256SUMS)
print "Notarized archive verified: $RELEASE_DIR/DriveExplorer.zip"
print "No GitHub release was published. Test the archive on a separate Gatekeeper-enabled Mac before distribution."
