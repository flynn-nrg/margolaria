#!/bin/sh
#
# release.sh: builds a signed, notarized and stapled Margolaria.app
# (docs/PLAN.md §7.2).
#
# Steps:
#   1. xcodebuild archive, Release configuration (Developer ID, Hardened Runtime).
#   2. xcodebuild -exportArchive with method "developer-id": re-signs the app
#      and every embedded framework for distribution.
#   3. Zip the app and send it to Apple's notary service; wait for the verdict.
#   4. Staple the notarization ticket to the app, so Gatekeeper can check it
#      offline, and zip the stapled app for distribution.
#   5. Verify: codesign --verify --deep --strict, then spctl --assess.
#
# One-time setup (stores the credentials in your login keychain; the script
# and repository never see them). Use an app-specific password from
# https://account.apple.com (Sign-In and Security > App-Specific Passwords):
#
#   xcrun notarytool store-credentials margolaria \
#       --apple-id you@example.com --team-id XXXXXXXXXX
#
# Usage, from anywhere in the repository:
#   scripts/release.sh                 # archive, export, notarize, staple, verify
#   scripts/release.sh --no-notarize   # archive, export and verify the signature only
#
# Environment:
#   NOTARY_PROFILE  keychain profile name (default: margolaria)
#
# Output, in build/release/:
#   Margolaria.xcarchive, Margolaria.app (stapled), Margolaria-<version>.zip,
#   notary-log.json (Apple's report on the submission).

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/release"
PROFILE=${NOTARY_PROFILE:-margolaria}
NOTARIZE=yes
if [ "${1:-}" = "--no-notarize" ]; then
    NOTARIZE=no
fi

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

# The project is generated from project.yml; make sure it is current.
xcodegen --quiet

# Read the team ID and version from the build settings (Signing.local.xcconfig
# and Base.xcconfig), so they are written down in one place only.
setting() {
    xcodebuild -scheme Margolaria -configuration Release -showBuildSettings 2>/dev/null \
        | sed -n "s/^ *$1 = //p" | head -1
}
TEAM=$(setting DEVELOPMENT_TEAM)
VERSION=$(setting MARKETING_VERSION)
if [ -z "$TEAM" ]; then
    echo "error: DEVELOPMENT_TEAM is empty; create Config/Signing.local.xcconfig (see the .example)" >&2
    exit 1
fi

echo "==> Archiving Margolaria $VERSION (team $TEAM)"
# ARCHS=arm64 on the command line: Config/Base.xcconfig sets it for the app,
# but Swift package targets (MargolariaKit) don't read the project's
# settings, and an archive builds them for Intel too, where some Swift
# APIs (Float16) don't exist. Settings given here apply to every target.
xcodebuild archive -quiet \
    -scheme Margolaria -configuration Release \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    -skipMacroValidation \
    -derivedDataPath "$ROOT/build/DerivedData" \
    -archivePath "$OUT/Margolaria.xcarchive"

echo "==> Exporting for Developer ID"
# Export options: distribute outside the App Store, signed by us. With manual
# signing, Xcode uses the Developer ID certificate already in the keychain.
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$TEAM</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet \
    -archivePath "$OUT/Margolaria.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT"
APP="$OUT/Margolaria.app"

echo "==> Checking the signature"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier|CodeDirectory)"

if [ "$NOTARIZE" = no ]; then
    echo "==> Skipping notarization (--no-notarize). Gatekeeper would reject this app on another Mac."
    exit 0
fi

echo "==> Notarizing (usually a few minutes)"
# notarytool takes a zip, dmg or pkg. `ditto -c -k --keepParent` makes a zip
# that keeps the symlinks and extended attributes inside the frameworks;
# plain `zip` would break the signatures.
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
# `|| true`: a rejected submission must not stop the script before the log
# (which says why) is downloaded below.
xcrun notarytool submit "$OUT/upload.zip" --keychain-profile "$PROFILE" \
    --wait --output-format plist > "$OUT/notary-submit.plist" || true
rm "$OUT/upload.zip"
SUBMISSION=$(/usr/libexec/PlistBuddy -c "Print :id" "$OUT/notary-submit.plist" 2>/dev/null || true)
STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$OUT/notary-submit.plist" 2>/dev/null || true)
if [ -z "$SUBMISSION" ]; then
    echo "error: the submission failed; see build/release/notary-submit.plist." >&2
    echo "       Is the keychain profile '$PROFILE' set up? (see the top of this script)" >&2
    exit 1
fi
xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" "$OUT/notary-log.json" > /dev/null
echo "    submission $SUBMISSION: $STATUS (details in build/release/notary-log.json)"
if [ "$STATUS" != "Accepted" ]; then
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple -q "$APP"
xcrun stapler validate -q "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Margolaria-$VERSION.zip"

echo "==> Asking Gatekeeper"
spctl --assess --type execute -vv "$APP"

echo "==> Done: $OUT/Margolaria-$VERSION.zip"
