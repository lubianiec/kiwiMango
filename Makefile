# kiwiMango – Build & Package Pipeline
# Targets: build, run, install, dmg, clean

APP_NAME     := kiwiMango
BUNDLE_ID    := com.kiwimango.app
# Auto-derived from git so every build is self-identifying — no more manual
# version bumps to remember, no more "czy to jest aktualne" guessing.
# Tag → "v1.2.0"; commits after tag → "v1.2.0-3-gabc1234"; uncommitted
# changes → "-dirty" suffix.
VERSION      ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

BUILD_DIR    := .build
RELEASE_DIR  := $(BUILD_DIR)/release
APP_BUNDLE   := $(abspath $(RELEASE_DIR)/$(APP_NAME).app)

ARCH         := arm64
SWIFT_TRIPLE := $(ARCH)-apple-macosx
BINARY       := $(BUILD_DIR)/$(SWIFT_TRIPLE)/release/$(APP_NAME)

# SPM resource bundle name: <TargetName>_<ModuleName>.bundle
RESOURCE_BUNDLE := $(APP_NAME)_$(APP_NAME).bundle
BUNDLE_SRC      := $(RELEASE_DIR)/$(RESOURCE_BUNDLE)

.PHONY: all build run install dmg clean status

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
	@echo "=== Code signing (stable local identity) ==="
	@# Ad-hoc signing ("--sign -") changes the app's CDHash on every rebuild,
	@# so macOS TCC treats each build as a brand-new app and re-asks for every
	@# permission (Photos, Music, Desktop, etc). Signing with a fixed local
	@# certificate keeps identity stable across builds so grants persist.
	@# Cert created once via: openssl req -x509 ... + security import/add-trusted-cert
	@# (CN "kiwiMango Local Dev", in login keychain). Falls back to ad-hoc if missing.
	codesign --force --deep --sign "kiwiMango Local Dev" "$(APP_BUNDLE)" 2>/dev/null || \
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

# ── Status: co jest gdzie, jednym spojrzeniem ─────────────────────────
status:
	@echo "=== kiwiMango — stan wersji ==="
	@git fetch origin main --quiet 2>/dev/null || echo "(brak sieci — pomijam fetch)"
	@LOCAL=$$(git rev-parse --short HEAD); \
	REMOTE=$$(git rev-parse --short origin/main 2>/dev/null || echo "?"); \
	DIRTY=$$(git status --porcelain | wc -l | tr -d ' '); \
	INSTALLED=$$(defaults read "/Applications/$(APP_NAME).app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "(brak w /Applications)"); \
	RELEASE=$$(gh release view --json tagName -q .tagName 2>/dev/null || echo "(brak/gh nie zalogowany)"); \
	echo "Lokalny commit:       $$LOCAL"; \
	echo "GitHub (origin/main): $$REMOTE"; \
	if [ "$$DIRTY" != "0" ]; then echo "Niezacommitowane zmiany: $$DIRTY plik(ów) ⚠️"; fi; \
	echo "Zainstalowana appka:  $$INSTALLED"; \
	echo "Ostatni release:      $$RELEASE"; \
	echo ""; \
	if [ "$$LOCAL" != "$$REMOTE" ]; then \
		echo "⚠️  Lokalny kod NIE jest zpushowany na GitHub."; \
	elif [ "$$DIRTY" != "0" ]; then \
		echo "⚠️  Masz niezacommitowane zmiany."; \
	else \
		echo "✅ Kod lokalny = GitHub main."; \
	fi
