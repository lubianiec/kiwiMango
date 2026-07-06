# kiwiMango – Build & Package Pipeline
# Targets: build, run, install, dmg, clean

APP_NAME     := kiwiMango
BUNDLE_ID    := com.kiwimango.app
VERSION      ?= 1.0.0

BUILD_DIR    := .build
RELEASE_DIR  := $(BUILD_DIR)/release
APP_BUNDLE   := $(abspath $(RELEASE_DIR)/$(APP_NAME).app)

ARCH         := arm64
SWIFT_TRIPLE := $(ARCH)-apple-macosx
BINARY       := $(BUILD_DIR)/$(SWIFT_TRIPLE)/release/$(APP_NAME)

# SPM resource bundle name: <TargetName>_<ModuleName>.bundle
RESOURCE_BUNDLE := $(APP_NAME)_$(APP_NAME).bundle
BUNDLE_SRC      := $(RELEASE_DIR)/$(RESOURCE_BUNDLE)

.PHONY: all build run install dmg clean

all: build

# ── Build Swift binary + assemble .app bundle ────────────────────────
build:
	@echo "=== Building $(APP_NAME) $(VERSION) for $(ARCH) ==="
	swift build -c release --arch $(ARCH)
	@echo "=== Assembling .app bundle ==="
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/"
	@echo "=== Writing Info.plist ==="
	@/usr/libexec/PlistBuddy -c "Add :CFBundleName string $(APP_NAME)" \
	    -c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
	    -c "Add :CFBundleVersion string $(VERSION)" \
	    -c "Add :CFBundleShortVersionString string $(VERSION)" \
	    -c "Add :CFBundleExecutable string $(APP_NAME)" \
	    -c "Add :CFBundlePackageType string APPL" \
	    -c "Add :CFBundleSignature string ????" \
	    -c "Add :LSMinimumSystemVersion string 26.0" \
	    -c "Add :NSPrincipalClass string NSApplication" \
	    -c "Add :NSHighResolutionCapable bool true" \
	    -c "Add :NSMicrophoneUsageDescription string 'kiwiMango używa mikrofonu do dyktowania wiadomości.'" \
	    -c "Add :NSSpeechRecognitionUsageDescription string 'kiwiMango zamienia mowę na tekst lokalnie.'" \
	    "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || true
	@echo "=== Copying SPM resource bundle ==="
	@if [ -d "$(BUNDLE_SRC)" ]; then \
		cp -r "$(BUNDLE_SRC)" "$(APP_BUNDLE)/Contents/Resources/"; \
		echo "    Copied $(RESOURCE_BUNDLE)"; \
	else \
		echo "    (no resource bundle — nothing to copy)"; \
	fi
	@echo "=== Copying AppIcon.icns ==="
	@if [ -f "AppIcon.icns" ]; then \
		cp "AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/"; \
		/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
		    "$(APP_BUNDLE)/Contents/Info.plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" \
		    "$(APP_BUNDLE)/Contents/Info.plist"; \
		echo "    Icon installed"; \
	else \
		echo "WARNING: AppIcon.icns not found — run create_icon.sh first"; \
	fi
	@echo "=== Code signing (ad-hoc) ==="
	codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo ""
	@echo "=== Build complete: $(APP_BUNDLE) ==="

# ── Run ──────────────────────────────────────────────────────────────
run: build
	open "$(APP_BUNDLE)"

# ── Install to /Applications ─────────────────────────────────────────
install: build
	rm -rf "/Applications/$(APP_NAME).app"
	ditto "$(APP_BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "=== Installed: /Applications/$(APP_NAME).app ==="

# ── DMG (do ~/Downloads) ─────────────────────────────────────────────
dmg: build
	$(eval STAGE := $(shell mktemp -d))
	ditto "$(APP_BUNDLE)" "$(STAGE)/$(APP_NAME).app"
	ln -s /Applications "$(STAGE)/Applications"
	rm -f "$(HOME)/Downloads/$(APP_NAME).dmg"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(STAGE)" -ov -format UDZO \
		"$(HOME)/Downloads/$(APP_NAME).dmg"
	rm -rf "$(STAGE)"
	@echo "=== DMG: $(HOME)/Downloads/$(APP_NAME).dmg ==="

# ── Clean ────────────────────────────────────────────────────────────
clean:
	rm -rf "$(BUILD_DIR)"
