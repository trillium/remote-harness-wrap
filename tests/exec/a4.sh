#!/bin/bash
# A4. A snapshot is applied on the remote without copying a secret
# unless that variable is on RW_ALLOW_VARS.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

canary="canary-9f3c2a7b"
snap="${RW_LOCAL_ROOT}/snap/env.sh"
mkdir -p "${RW_LOCAL_ROOT}/snap"
cat >"$snap" <<EOF
printf 'SNAP_OK\n'
hello() { printf 'hi\n'; }
export SAFE_MARKER=safe-ok
export RW_CANARY_SECRET=${canary}
EOF

script="source '${snap}' && hello && printf 'safe=%s\n' \"\$SAFE_MARKER\" && printf 'canary=%s\n' \"\${RW_CANARY_SECRET-UNSET}\""

remote_has_canary() {
  local found
  found=$(exec_ssh "grep -R -F -l -- $(printf '%q' "$canary") $(printf '%q' "$RW_REMOTE_ROOT") $(printf '%q' "${RW_BROKER_ROOT:-/tmp/rw-exec-broker}") 2>/dev/null || true")
  [[ -n "$found" ]]
}

out=$(mktemp "${TMPDIR:-/tmp}/rw-a4.XXXXXX")
RW_ALLOW_VARS="" exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$out" 2>"${RW_RAW}/a4-deny.err"
rc=$?
[[ "$rc" -eq 0 ]] && pass "denied snapshot command exit 0" || fail "denied snapshot command exit ${rc}"
if grep -F -q 'SNAP_OK' "$out" && grep -F -q 'hi' "$out" && grep -F -q 'safe=safe-ok' "$out"; then
  pass "snapshot still applies non-secret lines"
else
  fail "snapshot did not apply ordinary lines"
  cat "$out" | tee -a "$NOTES" || true
fi
if grep -F -q "$canary" "$out"; then
  fail "canary was printed when it was not allowlisted"
else
  pass "canary was not printed"
fi
if grep -F -q 'canary=UNSET' "$out"; then
  pass "canary variable was unset on the remote"
else
  fail "canary variable was not unset"
fi
if remote_has_canary; then
  fail "canary value is present on the remote"
else
  pass "canary value is absent on the remote"
fi

RW_ALLOW_VARS="RW_CANARY_SECRET" exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$out" 2>"${RW_RAW}/a4-allow.err"
rc=$?
[[ "$rc" -eq 0 ]] && pass "allowlisted snapshot command exit 0" || fail "allowlisted snapshot command exit ${rc}"
if grep -F -q "canary=${canary}" "$out"; then
  pass "allowlisted canary reached the remote command"
else
  fail "allowlisted canary did not reach the remote command"
  cat "$out" | tee -a "$NOTES" || true
fi
rm -f "$out"
exec_finish a4
