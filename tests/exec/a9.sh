#!/bin/bash
# A9. An unreachable remote fails loudly and does not run the command locally.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

outside="${TMPDIR:-/tmp}/rw-a9-outside-$$"
rm -f "$outside" "${RW_LOCAL_ROOT}/proj/a9-local"
script="printf 'RAN\n' > ${outside}; printf 'RAN\n' > ${RW_LOCAL_ROOT}/proj/a9-local"
err=$(mktemp "${TMPDIR:-/tmp}/rw-a9.XXXXXX")
saved_target="$RW_SSH_TARGET"
RW_SSH_TARGET="rw-unreachable.invalid"
export RW_CONNECT_TIMEOUT=3
exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"${RW_RAW}/a9-out.txt" 2>"$err"
rc=$?
RW_SSH_TARGET="$saved_target"

if [[ "$rc" -ne 0 ]]; then
  pass "unreachable target exits non-zero (${rc})"
else
  fail "unreachable target exited 0"
fi
if grep -F -q 'remote-bash:' "$err" && grep -F -q 'not run locally' "$err"; then
  pass "stderr names the failure and says the command was not run locally"
else
  fail "stderr was not a clear remote-bash failure"
  head -20 "$err" | tee -a "$NOTES" || true
fi
if [[ -e "$outside" || -e "${RW_LOCAL_ROOT}/proj/a9-local" ]]; then
  fail "command ran on the provider"
else
  pass "no provider side effect"
fi
rm -f "$outside" "$err"
exec_finish a9
