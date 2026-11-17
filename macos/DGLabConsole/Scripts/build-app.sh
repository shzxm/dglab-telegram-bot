#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Build the native SwiftUI executable without requiring a full Xcode install.
swift build --configuration release --jobs 2
OUT="$ROOT/build/DG-LAB Console.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$ROOT/.build/release/DGLabConsole" "$OUT/Contents/MacOS/DGLabConsole"
cp "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
chmod 755 "$OUT/Contents/MacOS/DGLabConsole"
/usr/bin/plutil -lint "$OUT/Contents/Info.plist"
# Ad-hoc signing is suitable for a local test build. It is NOT a Developer ID
# certificate or notarization for distribution to other Macs.
/usr/bin/codesign --force --sign - "$OUT"
/usr/bin/codesign --verify --strict --verbose=1 "$OUT"
echo "MAC_APP_BUNDLE=$OUT"
