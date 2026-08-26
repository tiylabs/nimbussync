#!/bin/sh
set -eu

if [ -n "${CI_SIGNING_KEYCHAIN:-}" ] && security list-keychains -d user | grep -Fq "$CI_SIGNING_KEYCHAIN"; then
    security delete-keychain "$CI_SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
fi

for uuid in ${CI_SIGNING_PROFILE_UUIDS:-}; do
    rm -f "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.provisionprofile"
done

if [ -n "${RUNNER_TEMP:-}" ]; then
    rm -rf "$RUNNER_TEMP/nimbussync-signing"
fi
