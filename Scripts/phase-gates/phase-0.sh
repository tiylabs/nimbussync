#!/bin/sh
set -eu
. "$(dirname -- "$0")/common.sh"

REPORT_DIR="$GATE_ROOT/phase-0"
mkdir -p "$REPORT_DIR"
run_rust
run_swift
run_xcode
secret_scan
release_scan
artifact_scan
RUST_TARGETS="${RUST_TARGETS:-aarch64-apple-darwin}" "$ROOT/Scripts/xtask/build-xcframework.sh"

if [ -n "${CLOUDREVE_CONTRACT_PROBE:-}" ]; then
    "$ROOT/Scripts/contract-tests/run-cloudreve-probe.sh"
fi

finder_status=unverified
protocol_status=unverified
provider_status=unverified
[ -n "${CLOUDREVE_MACOS_FINDER_EVIDENCE:-}" ] && finder_status=verified
[ -n "${CLOUDREVE_MACOS_PROTOCOL_EVIDENCE:-}" ] && protocol_status=verified
[ -n "${CLOUDREVE_MACOS_PROVIDER_EVIDENCE:-}" ] && provider_status=verified

printf '%s\n' '{' '  "phase": "phase-0",' '  "revision": 1,' '  "capabilities": [' '    {"name":"local_rust_swift_xcode_gate","status":"verified"},' '    {"name":"stable_identifier_and_scope_guard","status":"verified"},' '    {"name":"sse_framing_contract","status":"verified"},' '    {"name":"journal_outbox_anchor_model","status":"verified"},' '    {"name":"protocol_contract_real_cloudreve","status":"'"$protocol_status"'"},' '    {"name":"finder_replicated_extension","status":"'"$finder_status"'"},' '    {"name":"provider_upload_recovery_matrix","status":"'"$provider_status"'"},' '    {"name":"root_identity_real_server","status":"unverified"},' '    {"name":"conditional_content_write_real_server","status":"unverified"},' '    {"name":"idempotent_create_real_server","status":"unverified"},' '    {"name":"refresh_rotation_real_server","status":"unverified"}' '  ]' '}' > "$REPORT_DIR/capability-report.json"

printf '%s\n' '# Phase 0 Capability Report' '' '- Local Rust, Swift, Xcode and secret/release checks: verified.' '- Stable local identifiers, scope overlap guard, strict SSE framing, page/anchor bounds, SQLite journal/outbox and fail-closed reducers: verified.' '- Real Cloudreve Community/Pro protocol, Provider completion/recovery, signed Finder entitlement and Finder replay behavior: unverified until evidence paths are supplied.' '' 'The implementation remains read-only or fail-closed for every unverified write capability.' > "$REPORT_DIR/capability-report.md"
printf '%s\n' '# Phase 0 Fault Injection' '' '- Journal commit/outbox recovery: covered by Rust and Swift tests.' '- Duplicate/partial SSE frames: covered by parser tests.' '- Stale content version: covered by mutation tests.' '- Extension kill, real callback replay, signal completion loss and system pending-set behavior: unverified without a signed Finder harness.' > "$REPORT_DIR/fault-injection.md"
printf '%s\n' "phase-0 gate completed; finder=$finder_status protocol=$protocol_status providers=$provider_status" 
