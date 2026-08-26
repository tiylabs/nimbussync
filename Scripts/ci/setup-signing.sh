#!/bin/sh
set -eu

: "${APPLE_CERTIFICATE_BASE64:?APPLE_CERTIFICATE_BASE64 is required}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required}"
: "${NIMBUSSYNC_APP_PROFILE_BASE64:?NIMBUSSYNC_APP_PROFILE_BASE64 is required}"
: "${NIMBUSSYNC_FILE_PROVIDER_PROFILE_BASE64:?NIMBUSSYNC_FILE_PROVIDER_PROFILE_BASE64 is required}"
: "${NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE_BASE64:?NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE_BASE64 is required}"

WORK_ROOT=${RUNNER_TEMP:-/tmp}/nimbussync-signing
KEYCHAIN_PATH="$WORK_ROOT/build-signing.keychain-db"
KEYCHAIN_PASSWORD=${CI_SIGNING_KEYCHAIN_PASSWORD:-$(openssl rand -hex 24)}
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

umask 077
mkdir -p "$WORK_ROOT" "$PROFILE_DIR"

printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 -D > "$WORK_ROOT/signing.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$WORK_ROOT/signing.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -d user -s "$KEYCHAIN_PATH"

if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s\n' "CI_SIGNING_KEYCHAIN=$KEYCHAIN_PATH" >> "$GITHUB_ENV"
    printf '%s\n' "CI_SIGNING_KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD" >> "$GITHUB_ENV"
fi

install_profile() {
    value=$1
    label=$2
    encoded="$WORK_ROOT/$label.provisionprofile"
    decoded="$WORK_ROOT/$label.plist"

    printf '%s' "$value" | base64 -D > "$encoded"
    security cms -D -i "$encoded" -o "$decoded"
    uuid=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")
    cp "$encoded" "$PROFILE_DIR/$uuid.provisionprofile"
    printf '%s\n' "$uuid"
}

app_profile=$(install_profile "$NIMBUSSYNC_APP_PROFILE_BASE64" app)
file_provider_profile=$(install_profile "$NIMBUSSYNC_FILE_PROVIDER_PROFILE_BASE64" file-provider)
file_provider_ui_profile=$(install_profile "$NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE_BASE64" file-provider-ui)

identity=${APPLE_SIGNING_IDENTITY:-}
if [ -z "$identity" ]; then
    identity=$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed -n 's/.*"\(.*\)"/\1/p' | head -n 1)
fi
[ -n "$identity" ] || { printf '%s\n' 'no code-signing identity found in imported keychain' >&2; exit 1; }

if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s\n' "CI_SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
    printf '%s\n' "NIMBUSSYNC_APP_PROFILE=$app_profile" >> "$GITHUB_ENV"
    printf '%s\n' "NIMBUSSYNC_FILE_PROVIDER_PROFILE=$file_provider_profile" >> "$GITHUB_ENV"
    printf '%s\n' "NIMBUSSYNC_FILE_PROVIDER_UI_PROFILE=$file_provider_ui_profile" >> "$GITHUB_ENV"
    printf '%s\n' "CI_SIGNING_PROFILE_UUIDS=$app_profile $file_provider_profile $file_provider_ui_profile" >> "$GITHUB_ENV"
fi

printf '%s\n' 'signing assets installed in ephemeral CI keychain'
printf '%s\n' "identity: $identity"
printf '%s\n' "app profile: $app_profile"
printf '%s\n' "file provider profile: $file_provider_profile"
printf '%s\n' "file provider UI profile: $file_provider_ui_profile"
