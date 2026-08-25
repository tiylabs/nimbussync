#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
run_rust
run_swift
run_xcode
secret_scan
release_scan
artifact_scan
printf '%s\n' 'phase-2 local gate completed; Provider contract matrix remains unverified unless CLOUDREVE_MACOS_PROVIDER_EVIDENCE is supplied'
