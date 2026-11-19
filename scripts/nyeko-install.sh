#!/usr/bin/env bash
# Builds Nyeko and installs it as the only copy in /Applications.
#
# Signed with YOUR Apple Development certificate (a free Apple ID is enough), so macOS
# keeps Nyeko's permissions (Accessibility, microphone, ...) from one build to the next.
# An unsigned build looks like a new app every time and asks for everything again.
#
# One-time setup: Xcode → Settings → Accounts → add your Apple ID → Manage Certificates
# → + → Apple Development.
#
#   ./scripts/nyeko-install.sh                  # finds your Team ID by itself
#   NYEKO_TEAM_ID=ABCDE12345 ./scripts/nyeko-install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="com.broliix.nyeko"
DERIVED="${HOME}/Library/Developer/Xcode/DerivedData/NyekoDev"
BUILT="${DERIVED}/Build/Products/DebugLocal/Nyeko.app"
TARGET="/Applications/Nyeko.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

command -v xcodebuild >/dev/null || { echo "Xcode is missing: install it from the App Store, open it once, then run this again."; exit 1; }
command -v xcodegen  >/dev/null || { echo "XcodeGen is missing: brew install xcodegen"; exit 1; }

# Your Team ID: the OU of your Apple Development certificate.
TEAM_ID="${NYEKO_TEAM_ID:-}"
if [ -z "${TEAM_ID}" ]; then
  TEAM_ID=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
fi
if [ -z "${TEAM_ID}" ]; then
  echo "No Apple Development certificate found."
  echo "In Xcode: Settings → Accounts → add your Apple ID → Manage Certificates → + → Apple Development."
  echo "Or run with NYEKO_TEAM_ID=<your team id> ./scripts/nyeko-install.sh"
  exit 1
fi
echo "Signing with team ${TEAM_ID}."

echo "Building Nyeko (DebugLocal)..."
cd "${REPO_ROOT}/NotchBuddy"
xcodegen >/dev/null
xcodebuild -scheme Nyeko -configuration DebugLocal -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${TEAM_ID}" -derivedDataPath "${DERIVED}" -quiet build

echo "Quitting Nyeko..."
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x Nyeko >/dev/null || break; sleep 1; done
pkill -x Nyeko 2>/dev/null || true

# The app was called Kestrel before: its copy goes, so only Nyeko remains.
if [ -d "/Applications/Kestrel.app" ]; then
  osascript -e 'tell application id "com.broliix.kestrel" to quit' >/dev/null 2>&1 || true
  pkill -x Kestrel 2>/dev/null || true
  "${LSREGISTER}" -u "/Applications/Kestrel.app" >/dev/null 2>&1 || true
  rm -rf "/Applications/Kestrel.app"
  echo "Removed the old Kestrel.app."
fi

echo "Installing in ${TARGET}..."
rm -rf "${TARGET}"
ditto "${BUILT}" "${TARGET}"

# The build stays in DerivedData for faster next builds, but macOS must not count it as
# a second Nyeko.
"${LSREGISTER}" -u "${BUILT}" >/dev/null 2>&1 || true
"${LSREGISTER}" -f "${TARGET}" >/dev/null 2>&1 || true

open "${TARGET}"
echo "Nyeko is running from ${TARGET}."
