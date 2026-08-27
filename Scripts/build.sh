#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG_FILE=${NIMBUSSYNC_CONFIG:-"$ROOT/.nimbussyncrc"}
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
CONFIGURATION=${CONFIGURATION:-${NIMBUSSYNC_CONFIGURATION:-Debug}}
BUILD_ROOT=${BUILD_ROOT:-${NIMBUSSYNC_APP_BUILD_ROOT:-"$ROOT/.build/ci"}}
DIST_DIR=${DIST_DIR:-${NIMBUSSYNC_DIST_DIR:-"$ROOT/Dist"}}
VERSION=${VERSION:-${NIMBUSSYNC_VERSION:-0.1.0}}
SIGNING_MODE=${SIGNING_MODE:-${NIMBUSSYNC_SIGNING_MODE:-unsigned}}
APP_GROUP_IDENTIFIER=${APP_GROUP_IDENTIFIER:-${NIMBUSSYNC_APP_GROUP_IDENTIFIER:-group.ai.tiy.nimbussync}}
CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY:-${CI_SIGNING_IDENTITY:-${NIMBUSSYNC_CODE_SIGN_IDENTITY:-}}}

secret_scan() {
    if rg -n \
        --hidden \
        --glob '!Artifacts/**' \
        --glob '!.git/**' \
        --glob '!*.lock' \
        --glob '!Scripts/build.sh' \
        "(Bearer[[:space:]]+[A-Za-z0-9_-]{12,}|refresh_token[\"=:[:space:]]+[\"']?[A-Za-z0-9_-]{12,}[\"']?|signedUrl|signed_url)" \
        "$ROOT"; then
        printf '%s\n' 'secret scan found a credential-like value' >&2
        return 1
    fi
}

release_scan() {
    if rg -n \
        'com\.apple\.developer\.fileprovider\.testing-mode|NSAllowsArbitraryLoads|allowInsecure|http://localhost|http://127\.0\.0\.1' \
        "$ROOT/Config/Release.xcconfig" \
        "$ROOT/Config/NimbusSyncRelease.entitlements" \
        "$ROOT/Config/NimbusSyncFileProviderRelease.entitlements" \
        "$ROOT/Config/NimbusSyncFileProviderUI.entitlements" \
        "$ROOT/NimbusSync.xcodeproj"; then
        printf '%s\n' 'release scan found a forbidden entitlement or transport exception' >&2
        return 1
    fi
}

artifact_scan() {
    if [ -d "$ROOT/Artifacts" ] && rg -n \
        --hidden \
        '(access_token|refresh_token|callback_secret|upload_urls|signed_url|signedUrl|Authorization)' \
        "$ROOT/Artifacts"; then
        printf '%s\n' 'artifact scan found credential-like output' >&2
        return 1
    fi
}

secret_scan
release_scan
artifact_scan
git -C "$ROOT" diff --check

mkdir -p "$BUILD_ROOT" "$DIST_DIR"

set -- xcodebuild \
    -project "$ROOT/NimbusSync.xcodeproj" \
    -scheme NimbusSync \
    -configuration "$CONFIGURATION" \
    -destination platform=macOS \
    -derivedDataPath "$BUILD_ROOT/derived" \
    -clonedSourcePackagesDirPath "$BUILD_ROOT/source-packages" \
    -packageCachePath "$BUILD_ROOT/package-cache" \
    -skipPackageUpdates \
    build

case "$SIGNING_MODE" in
    unsigned)
        set -- "$@" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
        ;;
    signed)
        DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-${NIMBUSSYNC_DEVELOPMENT_TEAM:-}}
        NIMBUSSYNC_APP_PROFILE=${NIMBUSSYNC_APP_PROFILE:-${NIMBUSSYNC_APP_PROFILE_UUID:-}}
        NIMBUSSYNC_FILE_PROVIDER_PROFILE=${NIMBUSSYNC_FILE_PROVIDER_PROFILE:-${NIMBUSSYNC_FILE_PROVIDER_PROFILE_UUID:-}}
        NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE=${NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE:-${NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE_UUID:-}}
        : "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM or NIMBUSSYNC_DEVELOPMENT_TEAM is required for a signed build}"
        : "${CODE_SIGN_IDENTITY:?CODE_SIGN_IDENTITY is required for a signed build}"
        : "${NIMBUSSYNC_APP_PROFILE:?NIMBUSSYNC_APP_PROFILE is required for a signed build}"
        : "${NIMBUSSYNC_FILE_PROVIDER_PROFILE:?NIMBUSSYNC_FILE_PROVIDER_PROFILE is required for a signed build}"
        : "${NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE:?NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE is required for a signed build}"
        set -- "$@" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_ALLOWED=YES \
            CODE_SIGNING_REQUIRED=YES \
            CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
            DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
            APP_GROUP_IDENTIFIER="$APP_GROUP_IDENTIFIER" \
            NIMBUSSYNC_APP_PROFILE="$NIMBUSSYNC_APP_PROFILE" \
            NIMBUSSYNC_FILE_PROVIDER_PROFILE="$NIMBUSSYNC_FILE_PROVIDER_PROFILE" \
            NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE="$NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE"
        ;;
    *)
        printf '%s\n' "unsupported SIGNING_MODE: $SIGNING_MODE" >&2
        exit 2
        ;;
esac

"$@"

app="$BUILD_ROOT/derived/Build/Products/$CONFIGURATION/NimbusSync.app"
[ -d "$app" ] || { printf '%s\n' "missing built app: $app" >&2; exit 1; }

if [ "$SIGNING_MODE" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$app"
fi

# Keep the bundle name stable. Renaming a signed .app after codesign breaks the
# bundle-level signature even when the Mach-O executable still carries a valid signature.
artifact="$DIST_DIR/NimbusSync.app"
archive="$DIST_DIR/NimbusSync-$VERSION.zip"
rm -rf "$artifact" "$archive" "$archive.sha256"
ditto "$app" "$artifact"
if [ "$SIGNING_MODE" = signed ]; then
    codesign --verify --deep --strict --verbose=2 "$artifact"
fi
ditto -c -k --sequesterRsrc --keepParent "$artifact" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"

printf '%s\n' "built: $artifact"
printf '%s\n' "archive: $archive"
