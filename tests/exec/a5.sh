#!/bin/bash
# A5. Absolute paths are rewritten provider -> remote in the command,
# and remote -> provider in the output.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

local_abs="${RW_LOCAL_ROOT}/proj/abs.txt"
remote_abs="${RW_REMOTE_ROOT}/proj/abs.txt"
rm -f "$local_abs"
script="printf 'ABS\n' > ${local_abs}; printf '%s\n' ${local_abs}; pwd"
out=$(mktemp "${TMPDIR:-/tmp}/rw-a5.XXXXXX")
exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$out" 2>"${RW_RAW}/a5-err.txt"
rc=$?
[[ "$rc" -eq 0 ]] && pass "rewrite call exit 0" || fail "rewrite call exit ${rc}"

remote_body=$(exec_ssh "cat $(printf '%q' "$remote_abs")" 2>/dev/null || true)
remote_body=${remote_body%$'\n'}
if [[ "$remote_body" == "ABS" ]]; then
  pass "remote file is at the remote path"
else
  fail "remote file body [${remote_body}]"
fi
if [[ -f "$local_abs" ]]; then
  local_body=$(tr -d '\r\n' <"$local_abs")
  if [[ "$local_body" == "ABS" && "$remote_body" == "ABS" ]]; then
    pass "mirror pulled the rewritten file back to the provider"
  else
    fail "provider path was written on the provider"
  fi
else
  pass "provider path was not written on the provider"
fi

if grep -F -q "$RW_REMOTE_ROOT" "$out"; then
  fail "output still contains the remote prefix"
else
  pass "output does not contain the remote prefix"
fi
if grep -F -q "$local_abs" "$out"; then
  pass "output contains the provider path"
else
  fail "output missing the provider path"
fi
rm -f "$out"
exec_finish a5
