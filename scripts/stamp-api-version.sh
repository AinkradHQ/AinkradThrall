#!/usr/bin/env bash
#
# Stamps AinkradAPIVersion into the BUILT bundle's Info.plist, read from the
# AinkradAppKit revision this build actually linked against.
#
# ## Why
#
# `AinkradAPIVersion` was hand-typed as an integer in five Info.plists (four
# first-party plugins plus the template). The host loads a bundle only when that
# value is inside its supported generation range — so on any generation bump,
# forgetting one plist makes that plugin silently fail to load, with the failure
# recorded and (until Wave 0) never surfaced. A constant duplicated in five
# places, whose drift is invisible, is a bug waiting for a release.
#
# The value now comes from the SDK source in the resolved SwiftPM checkout, so
# the built bundle always declares the generation it was compiled against. The
# checked-in plist value becomes documentation rather than the authority.
#
# `scripts/preflight.sh` in the host repo still asserts the range independently —
# this generates, that verifies.
set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [[ ! -f "$PLIST" ]]; then
  # Never a warning. A skipped stamp leaves the stale hand-typed value in the
  # bundle, the host then refuses to load the plugin, and nothing says why —
  # the exact invisible failure this script exists to prevent. It has already
  # cost a debugging session once.
  echo "error: no Info.plist at $PLIST — refusing to ship an unverified AinkradAPIVersion" >&2
  echo "note: the script phase must run AFTER the Info.plist is copied into the bundle." >&2
  echo "note: check that project.yml declares inputFiles: [\$(TARGET_BUILD_DIR)/\$(INFOPLIST_PATH)]" >&2
  echo "note: on this phase, and that INFOPLIST_FILE / TARGET_BUILD_DIR are set for the target." >&2
  exit 1
fi

# Locate the SDK source. Two shapes, because both are real:
#   • revision-pinned  -> SwiftPM checkout beside the build products
#   • local path       -> the sibling working tree (development)
# The path also moved when the package was split into Contract/UI, so the
# pre-split location is still tried for a generation-7 checkout.
SDK_SOURCE=""
for candidate in \
  "${BUILD_DIR}/../../SourcePackages/checkouts/AinkradAppKit/Sources/AinkradAppKitContract/AinkradAPI.swift" \
  "${BUILD_DIR}/../../SourcePackages/checkouts/AinkradAppKit/Sources/AinkradAppKit/AinkradAPI.swift" \
  "${SRCROOT}/../AinkradAppKit/Sources/AinkradAppKitContract/AinkradAPI.swift" \
  "${SRCROOT}/../AinkradAppKit/Sources/AinkradAppKit/AinkradAPI.swift"
do
  [[ -f "$candidate" ]] && { SDK_SOURCE="$candidate"; break; }
done

if [[ -z "$SDK_SOURCE" ]]; then
  # Fail rather than silently leaving a stale hand-typed value — a wrong
  # AinkradAPIVersion means the host refuses to load this plugin, which is
  # precisely the invisible failure this script exists to prevent.
  echo "error: could not locate AinkradAppKit's AinkradAPI.swift — refusing to ship an unverified AinkradAPIVersion" >&2
  exit 1
fi

VERSION="$(grep -oE 'apiVersion[[:space:]]*=[[:space:]]*[0-9]+' "$SDK_SOURCE" | grep -oE '[0-9]+$' | head -1)"
[[ -n "$VERSION" ]] || { echo "error: could not read apiVersion from $SDK_SOURCE" >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Set :AinkradAPIVersion $VERSION" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :AinkradAPIVersion integer $VERSION" "$PLIST"

echo "AinkradAPIVersion stamped to $VERSION (from the linked AinkradAppKit)"
