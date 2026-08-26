#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEAM_ID=${NIMBUSSYNC_DEVELOPMENT_TEAM:-${1:-}}
BUILD_ROOT=${NIMBUSSYNC_SIGNED_BUILD_ROOT:-"$ROOT/.build/xcode-signed"}
ARCH=${NIMBUSSYNC_ARCH:-$(uname -m)}
APP_GROUP=${NIMBUSSYNC_APP_GROUP_IDENTIFIER:-group.ai.tiylabs.nimbussync}

if [ -z "$TEAM_ID" ]; then
    printf '%s\n' "usage: NIMBUSSYNC_DEVELOPMENT_TEAM=<TEAM_ID> $0" >&2
    printf '%s\n' "   or: $0 <TEAM_ID>" >&2
    exit 2
fi

case "$ARCH" in
    arm64|x86_64) ;;
    *) printf '%s\n' "unsupported architecture: $ARCH" >&2; exit 2 ;;
esac

mkdir -p "$BUILD_ROOT"

set -- xcodebuild \
    -project "$ROOT/NimbusSync.xcodeproj" \
    -scheme NimbusSync \
    -configuration Debug \
    -destination "platform=macOS,arch=$ARCH" \
    -derivedDataPath "$BUILD_ROOT" \
    -allowProvisioningUpdates

if [ "${NIMBUSSYNC_ALLOW_DEVICE_REGISTRATION:-0}" = 1 ]; then
    set -- "$@" -allowProvisioningDeviceRegistration
fi

set -- "$@" build \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    APP_GROUP_IDENTIFIER="$APP_GROUP"

"$@"

APP="$BUILD_ROOT/Build/Products/Debug/NimbusSync.app"
FILE_PROVIDER="$APP/Contents/PlugIns/NimbusSyncFileProvider.appex"
FILE_PROVIDER_UI="$APP/Contents/PlugIns/NimbusSyncFileProviderUI.appex"

for bundle in "$APP" "$FILE_PROVIDER" "$FILE_PROVIDER_UI"; do
    [ -d "$bundle" ] || { printf '%s\n' "missing signed bundle: $bundle" >&2; exit 1; }
    codesign --verify --strict "$bundle"
    signing_details=$(codesign -dv --verbose=4 "$bundle" 2>&1)
    team=$(printf '%s\n' "$signing_details" | sed -n 's/^TeamIdentifier=//p')
    if [ -z "$team" ] || [ "$team" = "not set" ]; then
        printf '%s\n' "bundle is not development-signed: $bundle" >&2
        exit 1
    fi
    if [ "$team" != "$TEAM_ID" ]; then
        printf '%s\n' "unexpected TeamIdentifier $team in $bundle; expected $TEAM_ID" >&2
        exit 1
    fi
done

for bundle in "$APP" "$FILE_PROVIDER"; do
    entitlements=$(codesign -d --entitlements :- "$bundle" 2>&1)
    if ! printf '%s\n' "$entitlements" | rg -Fq "<string>$APP_GROUP</string>"; then
        printf '%s\n' "missing App Group entitlement $APP_GROUP in $bundle" >&2
        exit 1
    fi
done

document_group=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionFileProviderDocumentGroup' "$FILE_PROVIDER/Contents/Info.plist")
if [ "$document_group" != "$APP_GROUP" ]; then
    printf '%s\n' "File Provider document group mismatch: $document_group" >&2
    exit 1
fi

printf '%s\n' "signed development build verified"
printf '%s\n' "app: $APP"
printf '%s\n' "team: $TEAM_ID"
printf '%s\n' "app group: $APP_GROUP"

if [ "${NIMBUSSYNC_OPEN_APP:-0}" = 1 ]; then
    open "$APP"
    printf '%s\n' "NimbusSync launched; verify registration with:"
    printf '%s\n' "pluginkit -m -i ai.tiylabs.nimbussync.fileprovider -A -D -v"
fi
