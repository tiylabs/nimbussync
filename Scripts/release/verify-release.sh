#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERSION=${VERSION:-0.1.0}
ARCHIVE="$ROOT/Dist/NimbusSync-$VERSION.zip"

[ -f "$ARCHIVE" ] || { echo "missing release archive: $ARCHIVE" >&2; exit 1; }
shasum -a 256 -c "$ARCHIVE.sha256"
unzip -q -l "$ARCHIVE" | rg 'NimbusSync\.app/Contents/PlugIns/NimbusSyncFileProvider\.appex|NimbusSync\.app/Contents/PlugIns/NimbusSyncFileProviderUI\.appex|NimbusSync\.app/Contents/Info\.plist'
if [ "${REQUIRE_SIGNED_RELEASE:-0}" = 1 ]; then
    codesign --verify --deep --strict "$ROOT/Dist/NimbusSync-$VERSION.app"
    spctl --assess --type execute "$ROOT/Dist/NimbusSync-$VERSION.app"
fi
