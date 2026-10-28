#!/bin/bash
# scripts/release.sh -- build Deskon.app (Release) into build/, sign it with a Developer ID,
# notarize and staple it.
#
# CODESIGN_IDENTITY names the "Developer ID Application: ... (TEAMID)" identity. Notarization uses
# NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) or APPLE_ID and
# APP_SPECIFIC_PASSWORD; the team id is the one in the identity name. Without both it stops before
# the build. The release workflow runs this same script.
#
# Usage: CODESIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=deskon scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:?set CODESIGN_IDENTITY to a Developer ID Application identity}"
APP=build/Deskon.app
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
  team=${IDENTITY##*\(}
  notary=(--apple-id "$APPLE_ID" --team-id "${team%)}" --password "$APP_SPECIFIC_PASSWORD")
else
  echo "set NOTARY_PROFILE, or APPLE_ID and APP_SPECIFIC_PASSWORD" >&2
  exit 1
fi

make xcode-build
rm -rf "$APP"
mkdir -p build
cp -R "$(make -s app-path XCODE_CONFIG=Release)" "$APP"
# MIT asks for the notice in every copy, and the release zip carries only the app.
cp LICENSE THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/"
# A tagged commit ships as that version; any other build keeps the one in project.yml.
if tag=$(git describe --tags --exact-match 2>/dev/null); then
  plutil -replace CFBundleShortVersionString -string "${tag#v}" "$APP/Contents/Info.plist"
fi
# Re-signing drops the get-task-allow entitlement Xcode injects into every non-archive build, which
# notarization rejects. The app has no entitlements of its own: hardened runtime gates neither
# CoreBluetooth nor SMAppService. An entitlements file added later must be passed with --entitlements.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

ditto -c -k --keepParent "$APP" "$APP.zip"
id=$(xcrun notarytool submit "$APP.zip" "${notary[@]}" --output-format json | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
rm -f "$APP.zip"
echo "notarization submission $id"
# The wait is a long poll; a dropped connection fails it without failing the submission.
status=""
for _ in 1 2 3; do
  status=$(xcrun notarytool wait "$id" "${notary[@]}" --output-format json | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p') && [ -n "$status" ] && break
  sleep 30
done
echo "notarization $status"
[ "$status" = Accepted ] || { xcrun notarytool log "$id" "${notary[@]}" >&2 || true; exit 1; }
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv -t exec "$APP"
