#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
run_rust
run_swift
run_xcode
secret_scan
release_scan
artifact_scan
printf '%s\n' 'phase-4 engineering gate completed; notarization, Gatekeeper, clean-machine install, upgrade and accessibility evidence require signing hardware and release credentials'
