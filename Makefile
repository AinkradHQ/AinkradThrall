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

# Publishing goes through scripts/release.sh, as it does in every other plugin
# repo. `ainkrad publish` is NOT sufficient on its own: it does not codesign,
# and the host demands a Developer-ID signature on every plugin as soon as the
# host itself carries one. An ad-hoc bundle is rejected before `Bundle.load()`,
# so it installs cleanly and then never appears — which is exactly what
# happened to v0.1.0.
#
# The warning this replaces said a bundled release.sh produces manifests the
# host refuses. That is true of the PLUGIN TEMPLATE's primitive copy, which
# hardcodes `apiVersion: 1`; it is not true of this one, which reads the
# stamped value out of the built bundle and updates the catalog.
releasebuild: generate
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath build \
	  -destination 'platform=macOS' build

# SIGN_IDENTITY is required for a release anyone can actually load:
#   SIGN_IDENTITY="Developer ID Application: ULINK sp. z o.o. (RT9AA68C38)" make release V=v0.1.0
release: ; ./scripts/release.sh $(V)

.PHONY: generate build test sideload release releasebuild
