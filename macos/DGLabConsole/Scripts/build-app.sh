#!/bin/zsh
# Build a self-contained DG-LAB macOS App. GUI compile can run on a second Mac
# with full Xcode, while Engine and native audio helper are bundled locally.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "${DG_GUI_BINARY:-}" ]]; then
  [[ -x "$DG_GUI_BINARY" ]] || { echo 'DG_GUI_BINARY is not executable' >&2; exit 3; }
  BIN="$DG_GUI_BINARY"
else
  swift build --configuration release --jobs 2
  BIN="$ROOT/.build/release/DGLabConsole"
fi

CACHE="${DG_RUNTIME_CACHE_DIR:-$HOME/Library/Caches/DGLabConsole/Runtime}"
for item in "$CACHE/bin/node" "$CACHE/bin/dglab-system-audio-meter" "$CACHE/Engine/dist/src/index.js" "$CACHE/Engine/node_modules"; do
  [[ -e "$item" ]] || { echo "Embedded runtime is missing: $item" >&2; exit 4; }
done

# Use a non-file-provider staging folder. iCloud/File Provider may reattach
# FinderInfo to an app placed under a synchronized source repository, which
# makes macOS reject an otherwise valid code signature.
OUTDIR="${DG_APP_OUTPUT_DIR:-$HOME/Library/Caches/DGLabConsole/Release}"
OUT="$OUTDIR/DG-LAB Console.app"
mkdir -p "$OUTDIR"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources/Engine"
/usr/bin/ditto "$BIN" "$OUT/Contents/MacOS/DGLabConsole"
/usr/bin/ditto "$CACHE/bin/node" "$OUT/Contents/Helpers/node"
/usr/bin/ditto "$CACHE/bin/dglab-system-audio-meter" "$OUT/Contents/Helpers/dglab-system-audio-meter"
/usr/bin/ditto "$CACHE/Engine" "$OUT/Contents/Resources/Engine"
/usr/bin/ditto "$ROOT/Resources/Info.plist" "$OUT/Contents/Info.plist"
chmod 755 "$OUT/Contents/MacOS/DGLabConsole" "$OUT/Contents/Helpers/node" "$OUT/Contents/Helpers/dglab-system-audio-meter"
/usr/bin/plutil -lint "$OUT/Contents/Info.plist"
# Assets from the official tarball and local File Provider may carry Finder
# metadata or quarantine extended attributes, both invalid inside codesigned
# app resource envelopes. Clean only the NEW output bundle.
/usr/bin/xattr -rc "$OUT" 2>/dev/null || true
# Ad-hoc signatures are valid only for local tests; no Developer ID notarization.
/usr/bin/codesign --force --sign - "$OUT/Contents/Helpers/node"
/usr/bin/codesign --force --sign - "$OUT/Contents/Helpers/dglab-system-audio-meter"
/usr/bin/codesign --force --sign - "$OUT"
/usr/bin/codesign --verify --deep --strict --verbose=1 "$OUT"
"$OUT/Contents/Helpers/node" --version
printf 'SELF_CONTAINED_APP=%s\n' "$OUT"
/usr/bin/du -sh "$OUT"
