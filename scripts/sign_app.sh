#!/usr/bin/env bash
#
# Sign OWAWidget.app inside-out: Sparkle's nested helpers, Sparkle.framework, the MCP bridge in
# Contents/Helpers, then the app.
# Single place for signing, shared by `make bundle` and scripts/test_update_locally.sh, so the
# update test exercises exactly the signature users get.
#
# Usage: scripts/sign_app.sh <path/to/OWAWidget.app> [identity]
#   identity "-" (default) - ad-hoc, for local builds;
#   any certificate name   - e.g. "Developer ID Application" for releases, or
#                            "Apple Development: Name (TEAMID)" for a stable dev identity.
#
# Why the two entitlements files:
#   Hardened runtime (--options runtime) is on for every identity. It turns on library
#   validation, which only loads code signed with the app's own Team ID. An ad-hoc signature has
#   no Team ID, so ad-hoc builds use OWAWidget-dev.entitlements, which disables *library
#   validation* specifically. Everything else hardened runtime provides stays on; most
#   importantly DYLD_* environment variables are ignored, so DYLD_INSERT_LIBRARIES cannot inject
#   code into this process to reach its Keychain items.
#   With a real certificate Sparkle is re-signed with the same Team ID and loads under library
#   validation, so OWAWidget.entitlements leaves it on (verified on a probe, 2026-10-05).
#
# Why nested code is signed one by one instead of with --deep:
#   --deep stamps the app's --entitlements onto every nested item, handing the calendars TCC
#   entitlement to Sparkle's Autoupdate, Updater.app and XPC services. Nested items are signed
#   without entitlements: the only one Sparkle ships, com.apple.application-identifier on
#   Autoupdate, is restricted and would get the helper killed at launch without a provisioning
#   profile. The order follows Sparkle's documentation for signing outside Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: sign_app.sh <app> [identity]}"
IDENTITY="${2:--}"
FRAMEWORK="${APP}/Contents/Frameworks/Sparkle.framework"

if [[ "${IDENTITY}" == "-" ]]; then
  ENTITLEMENTS="${ROOT_DIR}/OWAWidget/OWAWidget-dev.entitlements"
  # Ad-hoc signatures cannot carry a secure timestamp.
  TIMESTAMP=(--timestamp=none)
else
  ENTITLEMENTS="${ROOT_DIR}/OWAWidget/OWAWidget.entitlements"
  # Notarization rejects code without a secure timestamp.
  TIMESTAMP=(--timestamp)
fi

sign() {
  codesign --sign "${IDENTITY}" --force --options runtime "${TIMESTAMP[@]}" "$@"
}

if [[ -d "${FRAMEWORK}" ]]; then
  for xpc in "${FRAMEWORK}"/Versions/B/XPCServices/*.xpc; do
    [[ -e "${xpc}" ]] && sign "${xpc}"
  done
  sign "${FRAMEWORK}/Versions/B/Autoupdate"
  sign "${FRAMEWORK}/Versions/B/Updater.app"
  sign "${FRAMEWORK}"
fi

# Helper tools (the MCP bridge) carry no entitlements: the bridge only relays to the app's Unix
# socket and needs neither the network nor any TCC resource.
for helper in "${APP}"/Contents/Helpers/*; do
  [[ -f "${helper}" ]] && sign "${helper}"
done

sign --entitlements "${ENTITLEMENTS}" "${APP}"
codesign --verify --strict --deep "${APP}"
