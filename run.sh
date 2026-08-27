#!/bin/bash
# run.sh -- Build and launch LinakControl.app in debug mode.
# Kills any running instance first so the new build takes effect.
# Pass --clean to wipe persisted config (first-run / scanning mode).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="LinakControl"
CONFIG_DIR="$HOME/Library/Application Support/LinakControl"
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Kill running instance if any
if pgrep -xq "$APP_NAME"; then
    echo "Stopping running $APP_NAME..."
    killall "$APP_NAME" 2>/dev/null || true
    sleep 0.5
fi

# Optionally clear persisted config so the app starts in first-run mode.
if [ "$CLEAN" = true ] && [ -d "$CONFIG_DIR" ]; then
    echo "Clearing config at $CONFIG_DIR..."
    rm -rf "$CONFIG_DIR"
fi

echo "Building $APP_NAME (debug)..."
cd "$SCRIPT_DIR"
make xcode-build-debug 2>&1 | tail -5

# Ask the build system where the product is. A DerivedData glob picks by name
# order, so a second checkout of this repo can win and launch a stale build.
APP_PATH=$(make -s app-path XCODE_CONFIG=Debug)

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH does not exist after a successful build."
    exit 1
fi

echo "Launching $APP_PATH"
open "$APP_PATH"
