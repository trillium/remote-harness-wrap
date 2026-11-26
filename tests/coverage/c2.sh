#!/bin/bash
# C2. Claude Code read, write, and edit. The mirror pulls remote bytes
# before Read, and pushes the edited file before the next Bash command.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is not on PATH"
  coverage_finish c2
fi
note "claude: $(claude --version 2>/dev/null | head -1)"
note "model: haiku"

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj")" || fail "could not prepare the remote project"

prompt='Do these steps in order, then stop.
1. Use the Bash tool once. The command is: od -An -N4 -tx1 /dev/urandom | tr -d " \n" > remote-made.txt && echo RW_C2_BASH
2. Use the Read tool on remote-made.txt. Reply with the exact file contents.
3. Use the Write tool to create harness-wrote.txt whose only line is HARNESS_WRITE_ then those exact contents.
4. Use the Edit tool so the only line in harness-wrote.txt is HARNESS_EDIT_ then those exact contents.
5. Use the Bash tool once. The command is: echo RW_C2_PUSH
Do not print the environment, the home directory, or any credential.'

raw_log="${RW_RAW}/c2-argv.log"
: >"$raw_log"
out="${RW_RAW}/c2-claude.out"
err="${RW_RAW}/c2-claude.err"
(
  cd "$proj" || exit 97
  CLAUDE_CODE_SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    claude -p \
      --permission-mode bypassPermissions \
      --dangerously-skip-permissions \
      --allowedTools "Bash,Read,Write,Edit" \
      --effort low \
      --model haiku \
      "$prompt"
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
note "claude_exit: ${rc}"
exec_reject_secrets "$raw_log" || true
exec_reject_secrets "$out"
exec_reject_secrets "$err"

remote_made=$(exec_ssh "cat $(printf '%q' "$remote_proj/remote-made.txt") 2>/dev/null" || true)
remote_made=$(printf '%s' "$remote_made" | tr -d '\r\n')
if [[ -n "$remote_made" && ${#remote_made} -ge 8 ]]; then
  pass "the remote command wrote a file"
else
  fail "the remote command's file is missing"
fi
if [[ -n "$remote_made" ]] && { grep -F -q "$remote_made" "$out" || grep -F -q "$remote_made" "$err"; }; then
  pass "Read returned the token the remote command wrote"
else
  fail "Read did not return the remote token"
fi
remote_body=$(exec_ssh "cat $(printf '%q' "$remote_proj/harness-wrote.txt") 2>/dev/null" || true)
remote_body=$(printf '%s' "$remote_body" | tr -d '\r')
if [[ -n "$remote_made" && "$remote_body" == "HARNESS_EDIT_${remote_made}" ]]; then
  pass "the edited file is on the remote"
else
  fail "the edited file is not on the remote"
fi
if [[ "$rc" -eq 0 ]]; then
  pass "claude -p exited 0"
else
  fail "claude -p exited ${rc}"
fi
coverage_finish c2
