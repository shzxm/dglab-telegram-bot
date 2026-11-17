#!/bin/zsh
# Prepare the complete native macOS engine alongside the SwiftUI application.
# Requires Node/npm to build, but the final .app uses its own verified runtime.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUTPUT="$ROOT/macos/DGLabConsole/.runtime-cache"
NODE_VERSION='24.13.0'
NODE_PACKAGE="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_SHA256='d595961e563fcae057d4a0fb992f175a54d97fcc4a14dc2d474d92ddeea3b9f8'
cd "$ROOT"
npm run typecheck
npm run build
mkdir -p "$OUTPUT/bin" "$OUTPUT/Engine"
ARCHIVE="$OUTPUT/$NODE_PACKAGE"
if [[ ! -f "$ARCHIVE" ]]; then
  /usr/bin/curl -fL --retry 3 --connect-timeout 15 --max-time 240 \
    "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_PACKAGE}" -o "$ARCHIVE"
fi
ACTUAL="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL" != "$NODE_SHA256" ]]; then
  echo 'Refusing to use Node runtime: SHA256 mismatch' >&2; exit 11
fi
/usr/bin/tar -xOzf "$ARCHIVE" "node-v${NODE_VERSION}-darwin-arm64/bin/node" > "$OUTPUT/bin/node"
chmod 755 "$OUTPUT/bin/node"
# Preserve the official Node.js license and its bundled third-party notices.
# Production npm packages also keep their individual LICENSE files.
/usr/bin/tar -xOzf "$ARCHIVE" "node-v${NODE_VERSION}-darwin-arm64/LICENSE" > "$OUTPUT/Engine/NODEJS_LICENSE.txt"
"$OUTPUT/bin/node" --version
# Production package contains no TypeScript, build tools, tests, or developer secrets.
cp package.json package-lock.json "$OUTPUT/Engine/"
(cd "$OUTPUT/Engine" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
mkdir -p "$OUTPUT/Engine/dist"
/usr/bin/ditto "$ROOT/dist/src" "$OUTPUT/Engine/dist/src"
# All audio extraction is implemented locally by the original ScreenCaptureKit helper.
/usr/bin/swiftc -O -parse-as-library "$ROOT/native/system-audio-meter.swift" \
  -o "$OUTPUT/bin/dglab-system-audio-meter" \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia
chmod 755 "$OUTPUT/bin/dglab-system-audio-meter"
echo 'EMBEDDED_RUNTIME_READY'
du -sh "$OUTPUT/bin/node" "$OUTPUT/bin/dglab-system-audio-meter" "$OUTPUT/Engine"
