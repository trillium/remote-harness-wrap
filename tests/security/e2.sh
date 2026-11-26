#!/bin/bash
# E2. A secret in a provider shell startup file does not reach the remote
# unless that variable is allowlisted. After the allowlisted command, the
# value is removed and a second search is clean.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
sec_begin "$@"

token_file=$(sec_canary_file)
canary=$(sec_canary_value "$token_file")
RW_TOKEN_FILE="$token_file"
export RW_TOKEN_FILE
RW_EXTRA_CLEAN="rm -f $(printf '%q' "$token_file")"
export RW_EXTRA_CLEAN

snap="${RW_LOCAL_ROOT}/snap/env.sh"
mkdir -p "${RW_LOCAL_ROOT}/snap"
{
  printf 'printf "SNAP_OK\\n"\n'
  printf 'export SAFE_MARKER=safe-ok\n'
  printf 'export RW_CANARY_SECRET=%s\n' "$canary"
} >"$snap"
chmod 600 "$snap"

script="source '${snap}'
printf 'safe=%s\\n' \"\${SAFE_MARKER-UNSET}\"
if [ -n \"\${RW_CANARY_SECRET-}\" ]; then printf 'canary=set\\n'; else printf 'canary=unset\\n'; fi"

out=$(mktemp "${TMPDIR:-/tmp}/rw-e2.XXXXXX")
RW_ALLOW_VARS="" exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$out" 2>"${RW_RAW}/e2-deny.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F -q 'SNAP_OK' "$out" && grep -F -q 'safe=safe-ok' "$out"; then
  pass "startup file still applied ordinary lines"
else
  fail "startup file did not apply ordinary lines (exit ${rc})"
fi
if grep -F -q 'canary=unset' "$out"; then
  pass "startup secret was unset on the remote"
else
  fail "startup secret was not unset"
fi
if grep -F -q "$canary" "$out"; then
  fail "startup secret was printed"
else
  pass "startup secret was not printed"
fi
scan=$(sec_scan_remote "$canary" "$RW_REMOTE_ROOT" "$RW_BROKER_ROOT" | tail -n 1)
sec_scan_ok "$scan" || true

# Allowlisted exception: the value may cross, and teardown must remove it.
RW_ALLOW_VARS="RW_CANARY_SECRET" exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$out" 2>"${RW_RAW}/e2-allow.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F -q 'canary=set' "$out"; then
  pass "allowlisted startup secret was visible to that command"
else
  fail "allowlisted startup secret did not reach the command (exit ${rc})"
fi
present=$(sec_scan_remote "$canary" "$RW_REMOTE_ROOT" "$RW_BROKER_ROOT" | tail -n 1)
note "allow-scan ${present}"
if printf '%s\n' "$present" | grep -E -q 'hits_(scratch|broker|tmp|home|proc|other)=[1-9]'; then
  pass "allowlisted value was observable on the remote before cleanup"
else
  fail "allowlisted value was not observable on the remote"
fi
remote_snap=$(printf '%s' "$snap" | sed "s#${RW_LOCAL_ROOT}#${RW_REMOTE_ROOT}#")
exec_ssh "rm -f -- $(printf '%q' "$remote_snap")" >/dev/null 2>&1 || true
exec_stop_broker
scan=$(sec_scan_remote "$canary" "$RW_REMOTE_ROOT" "$RW_BROKER_ROOT" | tail -n 1)
sec_scan_ok "$scan" || true
rm -f "$out" "$snap"
exec_finish e2
