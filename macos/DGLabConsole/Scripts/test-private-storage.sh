#!/bin/zsh
# Local Swift security smoke test, never touches the real user App Support folder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(/usr/bin/mktemp -d -t DGLabPrivateStoreTests)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -D DEBUG -sdk "$SDK" -target arm64-apple-macos14.0 \
  -parse-as-library \
  "$ROOT/Sources/DGLabConsole/AppPrivateStorage.swift" \
  "$ROOT/Tests/PrivateStorageSmokeTest.swift" \
  -framework AppKit -o "$WORK/storage-check"
DGLAB_TEST_STORAGE_ROOT="$WORK/private-support" "$WORK/storage-check"
