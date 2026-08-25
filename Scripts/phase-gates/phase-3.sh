#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"
run_rust
run_swift
run_xcode
secret_scan
release_scan
artifact_scan
printf '%s\n' 'phase-3 local gate completed; 72-hour long-run and real SSE evidence remain unverified without a test deployment'
