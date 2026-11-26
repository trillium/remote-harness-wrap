#!/bin/bash
# C6. OpenCode file tools see remote files through the mirror.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v opencode >/dev/null 2>&1; then
  fail "opencode is not on PATH"
  coverage_finish c6
fi
note "opencode: $(opencode --version 2>/dev/null | head -1)"
note "model: opencode/big-pickle"

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj")" || fail "could not prepare the remote project"

prompt='Do these steps in order, then stop.
1. Use the bash tool once. The command is: od -An -N4 -tx1 /dev/urandom | tr -d " \n" > remote-made.txt && echo RW_C6_BASH
2. Use the read tool on remote-made.txt. Your reply must contain the exact file contents.
3. Use the write tool to create harness-wrote.txt whose only line is HARNESS_WRITE_ then those exact contents.
4. Use the bash tool once. The command is: echo RW_C6_PUSH
Do not print the environment, the home directory, or any credential.'

raw_log="${RW_RAW}/c6-argv.log"
: >"$raw_log"
out="${RW_RAW}/c6-opencode.out"
err="${RW_RAW}/c6-opencode.err"
(
  cd "$proj" || exit 97
  SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    opencode --pure run -m opencode/big-pickle --auto "$prompt"
) >"$out" 2>"$err" &
pid=$!
ticks=0
while kill -0 "$pid" 2>/dev/null && [[ "$ticks" -lt 240 ]]; do
  sleep 1
  ticks=$((ticks + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rc=124
else
  wait "$pid"
  rc=$?
fi
note "opencode_exit: ${rc}"
exec_reject_secrets "$raw_log" || true
exec_reject_secrets "$out"
exec_reject_secrets "$err"

remote_made=$(exec_ssh "cat $(printf '%q' "$remote_proj/remote-made.txt") 2>/dev/null" || true)
remote_made=$(printf '%s' "$remote_made" | tr -d '\r\n')
if [[ -n "$remote_made" ]] && { grep -F -q "$remote_made" "$out" || grep -F -q "$remote_made" "$err"; }; then
  pass "OpenCode read the token the remote command wrote"
else
  fail "OpenCode did not read the remote token"
fi
remote_body=$(exec_ssh "cat $(printf '%q' "$remote_proj/harness-wrote.txt") 2>/dev/null" || true)
remote_body=$(printf '%s' "$remote_body" | tr -d '\r')
if [[ -n "$remote_made" && "$remote_body" == "HARNESS_WRITE_${remote_made}" ]]; then
  pass "the file OpenCode wrote is on the remote"
else
  fail "the file OpenCode wrote is not on the remote"
fi
if [[ "$rc" -eq 0 ]]; then
  pass "opencode exited 0"
else
  fail "opencode exited ${rc}"
fi
coverage_finish c6
