#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/.nimbussyncrc"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
VERSION=${VERSION:-${NIMBUSSYNC_VERSION:-0.1.0}}
ARCHIVE="$ROOT/Dist/NimbusSync-$VERSION.zip"

[ -f "$ARCHIVE" ] || { echo "missing release archive: $ARCHIVE" >&2; exit 1; }
shasum -a 256 -c "$ARCHIVE.sha256"
unzip -q -l "$ARCHIVE" | rg 'NimbusSync\.app/Contents/PlugIns/NimbusSyncFileProvider\.appex|NimbusSync\.app/Contents/PlugIns/NimbusSyncFileProviderUI\.appex|NimbusSync\.app/Contents/Info\.plist'
if [ "${REQUIRE_SIGNED_RELEASE:-${NIMBUSSYNC_REQUIRE_SIGNED_RELEASE:-0}}" = 1 ]; then
    codesign --verify --deep --strict "$ROOT/Dist/NimbusSync.app"
    spctl --assess --type execute "$ROOT/Dist/NimbusSync.app"
fi
