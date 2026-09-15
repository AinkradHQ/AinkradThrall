#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
VERSION="${1:?usage: release.sh vX.Y.Z}"
ID="thrall"; NAME="Thrall"; ICON="cube.transparent"
DESC="Container manager framed around the stack: compose projects, crash-loop triage, logs and reclaim — over the engine you already run."

# Build CLEAN. An incremental build reuses whatever SwiftPM already resolved
# into build/SourcePackages — so after an SDK repin it can silently produce a
# bundle stamped with the PREVIOUS generation, which the host then refuses to
# load. That happened: a release went out declaring generation 7 against a
# generation-8 SDK. A release build is not the place to save 90 seconds.
rm -rf build

xcodegen generate
xcodebuild -scheme ThrallPlugin -configuration Release -derivedDataPath build -destination 'platform=macOS' build
BUNDLE="build/Build/Products/Release/ThrallPlugin.bundle"

rm -rf dist && mkdir -p dist
# --- sign ------------------------------------------------------------------
# Signed BEFORE zipping, deliberately: the catalog verifies the sha256 of the
# uploaded zip, so signing after packaging would ship an unsigned bundle whose
# checksum still matched perfectly.
#
# WHY this is not optional any more. The host's
# `PluginTrust.policyForCurrentBuild()` demands a Developer-ID signature on
# every plugin as soon as THE HOST ITSELF carries one. While the host was
# ad-hoc it fell back to `DevModeSignaturePolicy` and accepted anything --
# which is why these scripts never signed. A Developer-ID host plus an ad-hoc
# plugin means the plugin is REJECTED before `Bundle.load()`, and Ainkrad looks
# like it simply has no apps.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "> Signing with: ${SIGN_IDENTITY}"
  # Inside-out: nested code-bearing bundles first, then the plugin itself.
  # `--deep` is intentionally avoided (Apple discourages it).
  while IFS= read -r -d '' item; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$item"
  done < <(find "$BUNDLE/Contents" \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' \) -print0 2>/dev/null)
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BUNDLE"
  codesign --verify --strict --verbose=2 "$BUNDLE"
  # Assert it is a DEVELOPER ID signature -- not ad-hoc, not Apple Development.
  # The host checks this exact authority, so a wrong identity here ships a
  # plugin that installs cleanly and then never loads, with no error a user
  # could act on.
  # Captured into a variable rather than piped into `grep -q`. Under
  # `set -o pipefail` that pipeline FAILS EVEN WHEN THE MATCH SUCCEEDS: grep -q
  # exits the instant it matches, SIGPIPEs codesign, and pipefail reports the
  # dead writer. The first version of this check did exactly that and rejected
  # a correctly-signed bundle.
  SIG_DESC="$(codesign -dv --verbose=4 "$BUNDLE" 2>&1 || true)"
  case "$SIG_DESC" in
    *"Authority=Developer ID Application:"*) ;;
    *)
      echo "error: ${BUNDLE} is not Developer-ID signed -- the host will reject it" >&2
      exit 1
      ;;
  esac
else
  echo "warning: SIGN_IDENTITY is unset -- packaging an UNSIGNED plugin." >&2
  echo "         A Developer-ID-signed host REJECTS unsigned plugins, so this" >&2
  echo "         build will appear to install and then never load." >&2
fi

/usr/bin/ditto -c -k --keepParent "$BUNDLE" "dist/${ID}.bundle.zip"
SHA="$(shasum -a 256 "dist/${ID}.bundle.zip" | awk '{print $1}')"

# apiVersion READ FROM THE BUILT BUNDLE (stamped from the linked SDK by
# scripts/stamp-api-version.sh), never hardcoded — a stale constant here
# publishes a plugin the host refuses to load, silently.
API_VERSION="$(/usr/libexec/PlistBuddy -c 'Print AinkradAPIVersion' "$BUNDLE/Contents/Info.plist")"
[[ -n "$API_VERSION" ]] || { echo "error: could not read AinkradAPIVersion from the built bundle" >&2; exit 1; }

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "$ID", "name": "$NAME", "icon": "$ICON", "description": "$DESC", "apiVersion": $API_VERSION, "sha256": "$SHA",
  "author": "Ahmed M. Elhalaby" }
JSON

# `--target` is NOT optional. Without it `gh release create` tags the
# repository's DEFAULT BRANCH head, not the commit this bundle was built
# from -- so the uploaded zip and its sha256 can come from code the tag does
# not contain. That shipped: the host's v0.17.1 tag landed on the previous
# release's commit while its asset held 79 newer commits.
# Create, or repair an existing release by re-uploading its assets.
#
# `gh release create` fails outright on an existing tag, and under `set -e`
# that aborts the run BEFORE the catalog update below -- so a release that
# got as far as the tag but not the catalog could never be fixed by
# re-running the thing that made it. That is exactly what happened to
# Leyline v0.7.1. A re-run must be able to finish a half-finished release.
if gh release view "$VERSION" >/dev/null 2>&1; then
  echo "Release $VERSION exists - re-uploading assets."
  gh release upload "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" --clobber
else
  gh release create "$VERSION" dist/ainkrad-plugin.json "dist/${ID}.bundle.zip" \
    --target "$(git rev-parse HEAD)" \
    --title "$NAME $VERSION" --notes "$NAME $VERSION"
fi
echo "Released $VERSION (sha256 $SHA)"

# The GitHub release is NOT the release. The storefront reads catalog.json, and
# nothing else — so a run that stops at `gh release create` ships to nobody. That
# is exactly what happened to v0.7.0: published, tagged, downloadable, and
# invisible in the app for three days because the catalog still served v0.6.0.
# Updating the catalog is part of releasing, not a chore to remember afterwards.
SOURCE_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
CATALOG_REPO="AinkradHQ/AinkradCatalog"
CATALOG_DIR="$(mktemp -d)"
trap 'rm -rf "$CATALOG_DIR"' EXIT

# A FRESH clone every time, never a local checkout. Editing a working copy would
# let a release publish whatever unrelated edit or stale main happened to be
# sitting in it. Not shallow: we push from this clone.
gh repo clone "$CATALOG_REPO" "$CATALOG_DIR" -- --quiet

# Edited with a real JSON parser, never sed. The entry is located by appID, and a
# missing entry is a hard error — a pattern-match that quietly matches nothing is
# the same silent no-op that let the catalog drift in the first place.
ID="$ID" VERSION="$VERSION" SHA="$SHA" API_VERSION="$API_VERSION" SOURCE_REPO="$SOURCE_REPO" \
python3 - "$CATALOG_DIR/catalog.json" <<'PY'
import json, os, sys

path = sys.argv[1]
app_id, version = os.environ["ID"], os.environ["VERSION"]
sha, api_version = os.environ["SHA"], int(os.environ["API_VERSION"])
source_repo = os.environ["SOURCE_REPO"]

original = open(path, encoding="utf-8").read()
catalog = json.loads(original)

entries = [a for a in catalog["apps"] if a.get("appID") == app_id]
if not entries:
    known = ", ".join(a.get("appID", "?") for a in catalog["apps"])
    sys.exit(f"error: no catalog entry with appID '{app_id}' (found: {known})")
if len(entries) > 1:
    sys.exit(f"error: {len(entries)} catalog entries claim appID '{app_id}'")
entry = entries[0]

previous_api = entry.get("apiVersion")
entry["version"] = version
entry["apiVersion"] = api_version
entry["sha256"] = sha
entry["downloadURL"] = (
    f"https://github.com/{source_repo}/releases/download/{version}/{app_id}.bundle.zip"
)
for link in entry.get("links", []):
    if link.get("title") == "Release notes":
        link["url"] = f"https://github.com/{source_repo}/releases/tag/{version}"

# An apiVersion move is the one change here that can make the host refuse to
# install the plugin, so it is announced rather than slipped in silently.
if previous_api != api_version:
    print(f"note: apiVersion {previous_api} -> {api_version}")

updated = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"

# Validate BEFORE touching the file, and write via a temp + atomic replace. A
# half-written catalog.json takes down the storefront for every app, not just
# this one, so the original is never truncated in place.
json.loads(updated)
if len(updated) < len(original) // 2:
    sys.exit("error: rewritten catalog is implausibly small; refusing to write")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(updated)
os.replace(tmp, path)
PY

# Already current? Then this is a re-run, and there is nothing to push. Committing
# would fail under `set -e` and make a harmless repeat look like a broken release.
if git -C "$CATALOG_DIR" diff --quiet -- catalog.json; then
  echo "Catalog already lists $NAME $VERSION — nothing to push."
else
  git -C "$CATALOG_DIR" add catalog.json
  git -C "$CATALOG_DIR" commit -q -m "catalog: list $NAME $VERSION"
  git -C "$CATALOG_DIR" push -q origin HEAD:main
  echo "Catalog updated: $NAME $VERSION is now live in the storefront."
fi
