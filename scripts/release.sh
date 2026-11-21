#!/bin/sh
#
# release.sh: builds a signed, notarized and stapled Margolaria.app, and
# packs it as a .zip and as a .dmg (docs/PLAN.md §7.2).
#
# Steps:
#   1. xcodebuild archive, Release configuration (Developer ID, Hardened Runtime).
#   2. xcodebuild -exportArchive with method "developer-id": re-signs the app
#      and every embedded framework for distribution.
#   3. Zip the app and send it to Apple's notary service; wait for the verdict.
#   4. Staple the notarization ticket to the app, so Gatekeeper can check it
#      offline, and zip the stapled app for distribution.
#   5. Verify: codesign --verify --deep --strict, then spctl --assess.
#   6. Make a disk image of the stapled app beside a link to /Applications
#      (opened, it shows the two, to drag one onto the other); sign it,
#      notarize it and staple its own ticket, as for the app, and ask
#      Gatekeeper about it.
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
#   Margolaria-<version>.dmg (stapled), notary-log.json and
#   notary-log-dmg.json (Apple's reports on the two submissions).

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/release"
PROFILE=${NOTARY_PROFILE:-margolaria}
NOTARIZE=yes
if [ "${1:-}" = "--no-notarize" ]; then
    NOTARIZE=no
fi

cd "$ROOT"
# The last run's output goes first. rm -rf can fail with "Directory not
# empty" when something writes into the folder while it is being emptied
# (Spotlight or the Finder, indexing the last run's app); running the
# script again worked (2026-11-11). So it tries a few times, a second apart.
TRIES=0
until rm -rf "$OUT" 2>/dev/null; do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge 5 ]; then
        rm -rf "$OUT"   # once more, showing why it failed; set -e stops here
    fi
    sleep 1
done
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

# Sends a file to Apple's notary service and waits for the verdict; stops
# the script unless it is accepted. Usage: notarize FILE LOG; LOG is where
# Apple's report on the submission goes, in build/release.
notarize() {
    # `|| true`: a rejected submission must not stop the script before the
    # log (which says why) is downloaded below.
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" \
        --wait --output-format plist > "$OUT/notary-submit.plist" || true
    SUBMISSION=$(/usr/libexec/PlistBuddy -c "Print :id" "$OUT/notary-submit.plist" 2>/dev/null || true)
    STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$OUT/notary-submit.plist" 2>/dev/null || true)
    if [ -z "$SUBMISSION" ]; then
        echo "error: the submission failed; see build/release/notary-submit.plist." >&2
        echo "       Is the keychain profile '$PROFILE' set up? (see the top of this script)" >&2
        exit 1
    fi
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" "$OUT/$2" > /dev/null
    echo "    submission $SUBMISSION: $STATUS (details in build/release/$2)"
    if [ "$STATUS" != "Accepted" ]; then
        exit 1
    fi
}

echo "==> Notarizing the app (usually a few minutes)"
# notarytool takes a zip, dmg or pkg. `ditto -c -k --keepParent` makes a zip
# that keeps the symlinks and extended attributes inside the frameworks;
# plain `zip` would break the signatures.
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
notarize "$OUT/upload.zip" notary-log.json
rm "$OUT/upload.zip"

echo "==> Stapling"
xcrun stapler staple -q "$APP"
xcrun stapler validate -q "$APP"
ditto -c -k --keepParent "$APP" "$OUT/Margolaria-$VERSION.zip"

echo "==> Asking Gatekeeper"
spctl --assess --type execute -vv "$APP"

echo "==> Making the disk image"
# What the image holds: the stapled app (copied with ditto, which keeps the
# frameworks' symlinks and so the signature) and a link to /Applications.
# UDZO: compressed and read-only, which every macOS version opens.
DMG="$OUT/Margolaria-$VERSION.dmg"
mkdir "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Margolaria.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname Margolaria -srcfolder "$OUT/dmg" -format UDZO "$DMG"
rm -rf "$OUT/dmg"
# Signed with the certificate that signed the app: its full name, as
# codesign shows it ("Developer ID Application: Name (TEAM)"), so a keychain
# holding certificates of other teams can't make the choice ambiguous.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Notarizing the disk image"
notarize "$DMG" notary-log-dmg.json
xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"

echo "==> Asking Gatekeeper about the disk image"
# --type open with the primary-signature context: how Gatekeeper judges a
# downloaded disk image when it is opened.
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo "==> Done: $OUT/Margolaria-$VERSION.zip and $DMG"
