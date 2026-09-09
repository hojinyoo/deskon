#!/bin/bash
# scripts/take-screenshots.sh -- regenerate documentation screenshots.
# Runs the DeskonUITests scheme, exports XCUITest attachments to docs/screenshots/.
# Requires a real desk powered on and paired (no demo BLE mode).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

RESULT_BUNDLE="/tmp/linak-screenshots.xcresult"
OUT_DIR="docs/screenshots"
EXPORT_DIR="$(mktemp -d)"
DERIVED_DATA="$REPO_DIR/.build/xcode-screenshots"

for tool in xcodebuild xcodegen xcrun jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Error: $tool not found." >&2
        exit 1
    }
done

# The test targets the installed app at $LINAK_APP_PATH (default
# /Applications/Deskon.app) rather than the Debug build, so TCC
# Bluetooth permission survives across runs. Make sure it's there.
LINAK_APP_PATH="${LINAK_APP_PATH:-/Applications/Deskon.app}"
export LINAK_APP_PATH
if [ ! -d "$LINAK_APP_PATH" ]; then
    echo "Error: $LINAK_APP_PATH not found." >&2
    echo "Run ./install.sh first, or set LINAK_APP_PATH to an installed .app." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$RESULT_BUNDLE"

echo ">>> regenerating Xcode project"
xcodegen generate

# Use a repo-local DerivedData so the Deskon.app path is deterministic
# (the default ~/Library/Developer/Xcode/DerivedData/Deskon-<hash> hash
# changes whenever xcodegen rewrites the project).
mkdir -p "$DERIVED_DATA"

# Split build and run: xcodebuild test with -only-testing tends to skip
# rebuilding the host app, so the Debug Deskon.app can be missing
# when the runner's preflight goes looking for it.
echo ">>> building host app + UI test bundle"
xcodebuild build-for-testing \
    -project Deskon.xcodeproj \
    -scheme DeskonApp \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS' \
    2>&1 | tail -10

# xcodebuild's pre-test validation reads CFBundleIdentifier from
# $BUILT_PRODUCTS_DIR/$TEST_TARGET_NAME (no .app extension). Our product is
# Deskon.app, so the lookup misses unless we point a same-named symlink
# at the bundle. <path>/Contents/Info.plist then resolves through the symlink
# and the validator is happy.
DEBUG_DIR="$DERIVED_DATA/Build/Products/Debug"
if [ -d "$DEBUG_DIR/Deskon.app" ]; then
    ln -sfn Deskon.app "$DEBUG_DIR/Deskon"
else
    echo "Error: $DEBUG_DIR/Deskon.app not built — aborting." >&2
    exit 1
fi

echo ">>> running UI test target"
xcodebuild test-without-building \
    -project Deskon.xcodeproj \
    -scheme DeskonApp \
    -only-testing:DeskonUITests \
    -resultBundlePath "$RESULT_BUNDLE" \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'platform=macOS' \
    2>&1 | tail -40

echo ">>> exporting attachments"
xcrun xcresulttool export attachments \
    --path "$RESULT_BUNDLE" \
    --output-path "$EXPORT_DIR"

MANIFEST="$EXPORT_DIR/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "Error: $MANIFEST not produced by xcresulttool." >&2
    exit 1
fi

echo ">>> copying PNGs into $OUT_DIR/"
# manifest.json structure (per test):
#   { testIdentifier, attachments: [ { exportedFileName, suggestedHumanReadableName } ] }
# suggestedHumanReadableName format: "<attachment-name>_<index>_<uuid>.png"
# Strip the "_<index>_<uuid>" suffix to get a stable, human-friendly filename.
jq -r '.[].attachments[] | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "$MANIFEST" |
while IFS=$'\t' read -r exported human; do
    src="$EXPORT_DIR/$exported"
    clean="$(echo "$human" | sed -E 's/_[0-9]+_[0-9A-F-]{36}\.png$/.png/i')"
    if [ -f "$src" ]; then
        cp -v "$src" "$OUT_DIR/$clean"
    else
        echo "Warning: expected $src not found." >&2
    fi
done

echo ""
echo "Done. Screenshots in $OUT_DIR/:"
ls -lh "$OUT_DIR/"
