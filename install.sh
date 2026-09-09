#!/bin/bash
# install.sh -- Build Deskon.app in release mode and install to /Applications.
# The app runs as a menu bar utility (no Dock icon).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Deskon"
INSTALL_DIR="${1:-/Applications}"

# Preflight: required build tools
for tool in xcodebuild xcodegen; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            xcodebuild) echo "Error: xcodebuild not found. Install Xcode (or run: xcode-select --install)." ;;
            xcodegen)   echo "Error: xcodegen not found. Install with: brew install xcodegen" ;;
        esac
        exit 1
    fi
done

# Stop any running instance so the reinstall is clean
if pgrep -xq "$APP_NAME"; then
    echo "Stopping running $APP_NAME..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 0.5
fi

echo "Building $APP_NAME (release)..."
cd "$SCRIPT_DIR"
make xcode-build 2>&1 | tail -5

# Ask the build system where the product is. A DerivedData glob picks by name
# order, so a second checkout of this repo can win and install a stale build.
APP_PATH=$(make -s app-path XCODE_CONFIG=Release)

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH does not exist after a successful build."
    exit 1
fi

# Remove old installation if present
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "Removing old $INSTALL_DIR/$APP_NAME.app..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

echo "Installing to $INSTALL_DIR/$APP_NAME.app..."
cp -R "$APP_PATH" "$INSTALL_DIR/"

# Build and install deskctl CLI alongside the app
echo "Building deskctl CLI (release)..."
cd "$SCRIPT_DIR/LinakControl" && swift build -c release --product deskctl 2>&1 | tail -3
DESKCTL_SRC="$SCRIPT_DIR/LinakControl/.build/release/deskctl"

if [ -f "$DESKCTL_SRC" ]; then
    DESKCTL_DEST="/usr/local/bin/deskctl"
    echo "Installing deskctl to $DESKCTL_DEST..."
    install -m 755 "$DESKCTL_SRC" "$DESKCTL_DEST" 2>/dev/null || {
        echo "Need sudo for /usr/local/bin:"
        sudo install -m 755 "$DESKCTL_SRC" "$DESKCTL_DEST"
    }
    echo "CLI installed. Run 'deskctl --help' to verify."
fi

echo ""
echo "Launching $INSTALL_DIR/$APP_NAME.app..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "CLI commands:"
echo "  deskctl status        — Show desk status"
echo "  deskctl preset 2      — Move to preset 2"
echo "  deskctl config show   — Show configuration"
echo "  deskctl config reset  — Reset to defaults"
echo ""
echo "Or add to Login Items in System Settings for auto-start."
