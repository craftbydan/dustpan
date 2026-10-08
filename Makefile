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

.PHONY: all project build test lint format run clean install dmg site pages og

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
# The site's download button points at the GitHub release, not a copy hosted with the page.
GITHUB_REPO  := craftbydan/dustpan
DMG_URL      := https://github.com/$(GITHUB_REPO)/releases/download/v$(VERSION)/$(notdir $(DMG))
RELEASE_PAGE := https://github.com/$(GITHUB_REPO)/releases/tag/v$(VERSION)
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

# Landing page in site/: copies the rule book and licences next to index.html, writes
# release.json (version, size, SHA-256, GitHub download URL) and updates the download box.
# The DMG itself is served from the GitHub release. Run `make dmg` first.
site:
	@test -f $(DMG) || { echo "No $(DMG) — run make dmg first"; exit 1; }
	rm -f site/Dustpan-*.dmg
	cp Core/Rules/rules.json site/rules.json
	mkdir -p site/licenses
	cp THIRD_PARTY_NOTICES.md site/licenses/THIRD_PARTY_NOTICES.txt
	cp Core/Rules/RULES_ATTRIBUTION.md site/licenses/RULES_ATTRIBUTION.txt
	cp DesignSystem/Fonts/Archivo-OFL.txt site/licenses/Archivo-OFL.txt
	cp LICENSE site/licenses/LICENSE.txt
	printf '{"version":"%s","file":"%s","bytes":%s,"sha256":"%s","url":"%s","page":"%s"}\n' \
		"$(VERSION)" "$(notdir $(DMG))" "$$(stat -f %z $(DMG))" \
		"$$(shasum -a 256 $(DMG) | cut -d' ' -f1)" "$(DMG_URL)" "$(RELEASE_PAGE)" > site/release.json
	# The page also works without JavaScript; keep its static copy of the details in step.
	sed -i '' -E \
		-e "s#(<code id=\"shaValue\">)[0-9a-f]{64}#\1$$(shasum -a 256 $(DMG) | cut -d' ' -f1)#" \
		-e "s#https://github.com/$(GITHUB_REPO)/releases/download/[^\"]+#$(DMG_URL)#" \
		-e "s#https://github.com/$(GITHUB_REPO)/releases/tag/[^\"]+#$(RELEASE_PAGE)#" \
		-e "s#(<span id=\"relVersion\">)[^<]*#\1$(VERSION)#" \
		-e "s#(<span id=\"relFile\">)[^<]*#\1$(notdir $(DMG))#" \
		-e "s#(<span id=\"relSize\">)[^<]*#\1$$(stat -f %z $(DMG) | awk '{printf "%.1f MB", $$1/1e6}')#" \
		site/index.html
	@cat site/release.json
	@echo "Upload $(DMG) to the $(VERSION) GitHub release (see $(RELEASE_PAGE)), then publish site/."

# Publish the committed site/ folder to GitHub Pages (https://craftbydan.github.io/dustpan/).
# The main site is Vercel (https://dustpan.craftbydan.com/), which deploys main by itself.
# Pages serves the gh-pages branch, which is site/ split out of main's history.
pages:
	@git diff --quiet HEAD -- site || { echo "Commit your site/ changes first."; exit 1; }
	git subtree split --prefix site -b gh-pages-build
	git push origin gh-pages-build:gh-pages
	git branch -D gh-pages-build

# Link-preview image (site/og.png, 1200×630) rendered from Scripts/og/og.html with headless Chrome.
CHROME ?= /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
og:
	"$(CHROME)" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
		--force-device-scale-factor=1 --window-size=1200,630 --virtual-time-budget=3000 \
		--screenshot=site/og.png "file://$(CURDIR)/Scripts/og/og.html" 2>/dev/null
	@ls -l site/og.png

clean:
	rm -rf $(DERIVED_DATA)
