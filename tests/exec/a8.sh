#!/bin/bash
# A8. Twenty parallel commands do not interfere.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

work=$(mktemp -d "${TMPDIR:-/tmp}/rw-a8.XXXXXX")
i=1
while [[ "$i" -le 20 ]]; do
  (
    script="printf 'MARK-%s\n' '${i}' > ${RW_LOCAL_ROOT}/proj/p-${i}.txt; printf 'MARK-%s\n' '${i}'"
    exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"${work}/out-${i}" 2>"${work}/err-${i}"
    printf '%s\n' "$?" >"${work}/rc-${i}"
  ) &
  i=$((i + 1))
done
wait

i=1
ok=0
while [[ "$i" -le 20 ]]; do
  rc=$(tr -cd '0-9' <"${work}/rc-${i}")
  body=$(tr -d '\r' <"${work}/out-${i}")
  body=${body%$'\n'}
  remote_body=$(exec_ssh "cat $(printf '%q' "${RW_REMOTE_ROOT}/proj/p-${i}.txt")" 2>/dev/null || true)
  remote_body=${remote_body%$'\n'}
  if [[ "$rc" == 0 && "$body" == "MARK-${i}" && "$remote_body" == "MARK-${i}" ]]; then
    ok=$((ok + 1))
  else
    fail "command ${i}: rc=${rc} out=[${body}] remote=[${remote_body}]"
  fi
  i=$((i + 1))
done
if [[ "$ok" -eq 20 ]]; then
  pass "20 parallel commands each returned their own marker"
else
  fail "${ok} of 20 commands matched"
fi
rm -rf "$work"
exec_finish a8
