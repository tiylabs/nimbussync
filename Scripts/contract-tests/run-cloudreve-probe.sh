#!/bin/sh
set -eu

: "${CLOUDREVE_ORIGIN:?set CLOUDREVE_ORIGIN to run the contract probe}"
: "${CLOUDREVE_ACCESS_TOKEN:?set CLOUDREVE_ACCESS_TOKEN to run the contract probe}"

case "$CLOUDREVE_ORIGIN" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) [ "${CLOUDREVE_ALLOW_LOOPBACK_HTTP:-0}" = 1 ] || { echo 'loopback HTTP requires CLOUDREVE_ALLOW_LOOPBACK_HTTP=1' >&2; exit 1; } ;;
    *) echo 'CLOUDREVE_ORIGIN must use HTTPS' >&2; exit 1 ;;
esac

report_dir=${CLOUDREVE_PROBE_REPORT_DIR:-Artifacts/PhaseGates/phase-0}
mkdir -p "$report_dir"
tmp_body=$(mktemp)
trap 'rm -f "$tmp_body"' EXIT

request() {
    path=$1
    curl --fail-with-body --silent --show-error --location --max-redirs 0 \
        --header "Authorization: Bearer $CLOUDREVE_ACCESS_TOKEN" \
        --header 'Accept: application/json' \
        --output "$tmp_body" --write-out '%{http_code}' "$CLOUDREVE_ORIGIN/api/v4/$path"
}

user_status=$(request user/me || true)
if [ "$user_status" != 200 ]; then
    echo "user/me returned HTTP $user_status" >&2
    exit 1
fi

user_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp_body" | head -1)
[ -n "$user_id" ] || { echo 'user/me response did not contain an account id' >&2; exit 1; }

cat > "$report_dir/protocol-probe.json" <<EOF
{
  "origin": "redacted",
  "account_id_present": true,
  "user_me_http_status": $user_status,
  "stable_item_identity": "unverified",
  "stable_root_identity": "unverified",
  "conditional_content_write": "unverified",
  "idempotent_create": "unverified",
  "trash_restore": "unverified",
  "upload_recovery": "unverified",
  "refresh_rotation": "unverified"
}
EOF

echo 'contract probe completed without printing credentials or response bodies'

