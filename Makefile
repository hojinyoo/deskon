# Makefile — linak-control
# Builds, tests, and installs LinakControl (menu bar app) and deskctl (CLI).
# Targets operate on the Swift Package at LinakControl/.

SWIFT_PKG_DIR := LinakControl
BUILD_DIR     := $(SWIFT_PKG_DIR)/.build
RELEASE_DIR   := $(BUILD_DIR)/release

APP_BINARY    := LinakControl
CLI_BINARY    := deskctl

INSTALL_BIN   ?= /usr/local/bin
INSTALL_APP   ?= /Applications

# Xcode project — produces a proper .app bundle required for BLE entitlements,
# Info.plist embedding (LSUIElement, NSBluetoothAlwaysUsageDescription), and
# SMAppService (login item) which all require a bundle identifier.
XCODEPROJ     := LinakControl.xcodeproj
XCODE_SCHEME  := LinakControlApp
XCODE_CONFIG  ?= Debug

.PHONY: help build build-debug xcode-build xcode-build-debug app-path generate-xcodeproj test install clean lint

help: ## Show available targets
	@printf "Usage: make <target>\n\n"
	@printf "Targets:\n"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

build: ## Build both targets in release mode (raw binaries via SPM)
	cd $(SWIFT_PKG_DIR) && swift build -c release

build-debug: ## Build both targets in debug mode (raw binaries via SPM)
	cd $(SWIFT_PKG_DIR) && swift build

xcode-build: generate-xcodeproj ## Build LinakControl.app bundle in release mode via Xcode
	xcodebuild -project $(XCODEPROJ) -scheme $(XCODE_SCHEME) -configuration Release build

xcode-build-debug: generate-xcodeproj ## Build LinakControl.app bundle in debug mode via Xcode
	xcodebuild -project $(XCODEPROJ) -scheme $(XCODE_SCHEME) -configuration Debug build

app-path: ## Print the built .app path for XCODE_CONFIG (Debug or Release)
	@dir=$$(xcodebuild -project $(XCODEPROJ) -scheme $(XCODE_SCHEME) -configuration $(XCODE_CONFIG) -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1); \
	if [ -z "$$dir" ]; then printf "xcodebuild did not report BUILT_PRODUCTS_DIR for $(XCODE_CONFIG)\n" >&2; exit 1; fi; \
	printf "%s/%s.app\n" "$$dir" "$(APP_BINARY)"

generate-xcodeproj: ## Regenerate LinakControl.xcodeproj from project.yml (requires xcodegen)
	@command -v xcodegen >/dev/null 2>&1 || (printf "xcodegen not found — run: brew install xcodegen\n" && exit 1)
	xcodegen generate

test: ## Run the test suite
	cd $(SWIFT_PKG_DIR) && swift test

install: build ## Install deskctl CLI binary (set INSTALL_BIN to override)
	@printf "Installing $(CLI_BINARY) to $(INSTALL_BIN)/$(CLI_BINARY)\n"
	install -m 755 $(RELEASE_DIR)/$(CLI_BINARY) $(INSTALL_BIN)/$(CLI_BINARY)
	@printf "Done. Run '$(CLI_BINARY) --help' to verify.\n"

clean: ## Remove build artifacts (SPM and Xcode DerivedData)
	cd $(SWIFT_PKG_DIR) && swift package clean
	xcodebuild -project $(XCODEPROJ) -scheme $(XCODE_SCHEME) clean 2>/dev/null || true

lint: ## Run SwiftLint if available
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint $(SWIFT_PKG_DIR)/Sources; \
	else \
		printf "swiftlint not found — skipping lint\n"; \
	fi
