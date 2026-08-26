#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

secret_scan() {
    if rg -n \
        --hidden \
        --glob '!Artifacts/**' \
        --glob '!.git/**' \
        --glob '!*.lock' \
        --glob '!Scripts/ci/verify.sh' \
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

printf '%s\n' 'secret, Release entitlement, artifact and whitespace checks passed'
