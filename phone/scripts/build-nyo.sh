#!/usr/bin/env bash
# Builds phone/web/nyo.js (Nyo for the web app) from the Windows app's painter, windows/src/mochi/nyo.ts, so the phone
# draws the same cat as the Mac, Windows and Android. Needs `npm install` in windows/. Commit the result.
set -euo pipefail
cd "$(dirname "$0")/../.."
windows/node_modules/.bin/esbuild windows/src/mochi/nyo.ts --bundle --format=esm --minify --outfile=phone/web/nyo.js \
  --banner:js="// Nyo, built from windows/src/mochi/nyo.ts by phone/scripts/build-nyo.sh (do not edit). © 2026 Rohil Sagar, all rights reserved (LICENSE-ASSETS.md)."
