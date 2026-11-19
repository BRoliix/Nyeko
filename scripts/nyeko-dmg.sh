#!/usr/bin/env bash
# Builds the Nyeko Mac installer: dist/Nyeko-<version>.dmg (Nyeko.app and a shortcut to Applications: drag one onto
# the other). Signed with YOUR Apple Development certificate, like scripts/nyeko-install.sh, so a Mac that already
# runs Nyeko keeps its permissions (Accessibility, microphone…) and its Keychain items when you install from it.
#
#   ./scripts/nyeko-dmg.sh                       # finds your Team ID by itself
#   NYEKO_TEAM_ID=ABCDE12345 ./scripts/nyeko-dmg.sh
#
# Opening it on another Mac: the app is not notarized, so the first time macOS says it can't check it. Right-click
# Nyeko in Applications → Open → Open (or System Settings → Privacy & Security → Open Anyway).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/NyekoDmg"
BUILT="${DERIVED}/Build/Products/DebugLocal/Nyeko.app"
OUT="${REPO_ROOT}/dist"

command -v xcodebuild >/dev/null || { echo "Xcode is missing: install it from the App Store, open it once, then run this again."; exit 1; }
command -v xcodegen  >/dev/null || { echo "XcodeGen is missing: brew install xcodegen"; exit 1; }

TEAM_ID="${NYEKO_TEAM_ID:-}"
if [ -z "${TEAM_ID}" ]; then
  TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
fi
if [ -z "${TEAM_ID}" ]; then
  echo "No Apple Development certificate found."
  echo "In Xcode: Settings → Accounts → add your Apple ID → Manage Certificates → + → Apple Development."
  exit 1
fi
echo "Signing with team ${TEAM_ID}."

echo "Building Nyeko..."
cd "${REPO_ROOT}/NotchBuddy"
xcodegen >/dev/null
xcodebuild -scheme Nyeko -configuration DebugLocal -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM_ID}" -derivedDataPath "${DERIVED}" -quiet build

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUILT}/Contents/Info.plist")
DMG="${OUT}/Nyeko-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

echo "Making the disk image..."
ditto "${BUILT}" "${STAGE}/Nyeko.app"
ln -s /Applications "${STAGE}/Applications"
mkdir -p "${OUT}"
rm -f "${DMG}"
hdiutil create -volname "Nyeko" -srcfolder "${STAGE}" -ov -format UDZO -quiet "${DMG}"

# The build stays in DerivedData for faster next builds, but macOS must not count it as a second Nyeko.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -u "${BUILT}" >/dev/null 2>&1 || true

echo "Done: ${DMG}"
echo "SHA-256: $(shasum -a 256 "${DMG}" | cut -d' ' -f1)"
open -R "${DMG}"
