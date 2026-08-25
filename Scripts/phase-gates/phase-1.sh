#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
run_rust
run_swift
run_xcode
secret_scan
release_scan
artifact_scan
printf '%s\n' 'phase-1 local gate completed; real multi-domain, Keychain access-group and 100k Finder scale evidence remain environment-dependent'
