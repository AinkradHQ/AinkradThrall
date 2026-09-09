DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
export DEVELOPER_DIR
# The sideload directory is `<cacheRoot>/DevPlugins`, and cacheRoot is
# `~/Library/Application Support/<bundle-id>/Cache` (AinkradHome.defaultCacheRoot).
# Deliberately NOT under the user's Ainkrad Home: dev plugin bundles are
# rebuildable machine state, not vault data.
DEV_PLUGINS := $(HOME)/Library/Application Support/com.ainkrad.app/Cache/DevPlugins
SCHEME := ThrallPlugin

generate: ; xcodegen generate

build: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build \
	  -destination 'platform=macOS' build

test: generate
	xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath build \
	  -destination 'platform=macOS' test

sideload: build
	mkdir -p "$(DEV_PLUGINS)"
	rm -rf "$(DEV_PLUGINS)/ThrallPlugin.bundle"
	cp -R build/Build/Products/Debug/ThrallPlugin.bundle "$(DEV_PLUGINS)/ThrallPlugin.bundle"

# Publishing goes through `ainkrad publish` and nowhere else. A bundled
# release.sh that assembles its own ainkrad-plugin.json is a second publish
# path producing manifests the host's StorePolicy refuses; the template's copy
# was deleted for exactly that reason. Do not reintroduce one.
releasebuild: generate
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath build \
	  -destination 'platform=macOS' build

release: releasebuild
	ainkrad publish build/Build/Products/Release/ThrallPlugin.bundle $(V)

.PHONY: generate build test sideload release releasebuild
