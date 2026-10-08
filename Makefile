# Dustpan developer tasks. Requires Xcode and XcodeGen (`brew install xcodegen`).

# Use the full Xcode even if xcode-select points at the Command Line Tools.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

SCHEME       := Dustpan
DESTINATION  := platform=macOS
DERIVED_DATA := build
XCODEBUILD   := xcodebuild -project Dustpan.xcodeproj -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED_DATA)
APP          := $(DERIVED_DATA)/Build/Products/Debug/Dustpan.app
LINT_PATHS   := App Core DesignSystem Features Tests

.PHONY: all project build test lint format run clean install dmg site

all: build

Config.xcconfig:
	cp Config.example.xcconfig Config.xcconfig

project: Config.xcconfig
	xcodegen generate

build: Config.xcconfig
	$(XCODEBUILD) build

test: Config.xcconfig
	$(XCODEBUILD) test

lint:
	xcrun swift-format lint --strict -r $(LINT_PATHS)

format:
	xcrun swift-format format -i -r $(LINT_PATHS)

run: build
	open $(APP)

# Release build, ad-hoc signed (local use only), copied to /Applications.
# macOS forgets Full Disk Access when the signature changes, so re-grant it after installing.
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Dustpan.app
install: Config.xcconfig
	$(XCODEBUILD) -configuration Release build
	@if pgrep -xq Dustpan; then echo "Quit Dustpan first."; exit 1; fi
	rm -rf /Applications/Dustpan.app
	ditto $(RELEASE_APP) /Applications/Dustpan.app
	@echo "Installed /Applications/Dustpan.app. Grant it Full Disk Access in System Settings › Privacy & Security."

# Drag-to-Applications disk image in dist/ (needs `brew install create-dmg`).
# Ad-hoc signed and not notarized: fine on this Mac; other Macs will refuse to open it.
VERSION := $(shell grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"(.*)".*/\1/')
DMG     := dist/Dustpan-$(VERSION).dmg
dmg: Config.xcconfig
	$(XCODEBUILD) -configuration Release build
	rm -rf dist/stage $(DMG) && mkdir -p dist/stage
	ditto $(RELEASE_APP) dist/stage/Dustpan.app
	create-dmg --volname "Dustpan" --background Scripts/dmg/background.tiff \
		--window-pos 200 120 --window-size 660 400 --icon-size 128 --text-size 13 \
		--icon "Dustpan.app" 170 220 --hide-extension "Dustpan.app" \
		--app-drop-link 490 220 --no-internet-enable $(DMG) dist/stage
	rm -rf dist/stage
	@echo "Built $(DMG)"

# Landing page in site/: copies the DMG, the rule book and the app icon next to index.html
# and writes release.json (version, size, SHA-256) for the download box. Run `make dmg` first.
site:
	@test -f $(DMG) || { echo "No $(DMG) — run make dmg first"; exit 1; }
	rm -f site/Dustpan-*.dmg
	cp $(DMG) site/
	cp Core/Rules/rules.json site/rules.json
	mkdir -p site/licenses
	cp THIRD_PARTY_NOTICES.md site/licenses/THIRD_PARTY_NOTICES.txt
	cp Core/Rules/RULES_ATTRIBUTION.md site/licenses/RULES_ATTRIBUTION.txt
	cp DesignSystem/Fonts/Archivo-OFL.txt site/licenses/Archivo-OFL.txt
	cp LICENSE site/licenses/LICENSE.txt
	printf '{"version":"%s","file":"%s","bytes":%s,"sha256":"%s"}\n' \
		"$(VERSION)" "$(notdir $(DMG))" "$$(stat -f %z $(DMG))" \
		"$$(shasum -a 256 $(DMG) | cut -d' ' -f1)" > site/release.json
	# The page also shows the checksum without JavaScript; keep that copy in step.
	sed -i '' -E "s#(<code id=\"shaValue\">)[0-9a-f]{64}#\1$$(shasum -a 256 $(DMG) | cut -d' ' -f1)#" site/index.html
	@cat site/release.json

clean:
	rm -rf $(DERIVED_DATA)
