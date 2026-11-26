#!/bin/bash
# C4. Read stays on the provider when the session authenticates.
# A refused account is recorded as not-observed. Hook locality is recorded by c1.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

token_file="${RW_TOKEN_FILE:-}"
if [[ -z "$token_file" || ! -s "$token_file" ]]; then
  fail "RW_TOKEN_FILE is missing"
  coverage_finish c4
fi
note "token file: present"

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
printf 'rw-local-only-marker\n' >"$proj/local-only-marker.txt"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj") && printf 'rw-remote-only-marker\n' > $(printf '%q' "$remote_proj/remote-only-marker.txt")" \
  || fail "could not place the remote marker"

settings="${RW_RAW}/c4-settings.json"
printf '%s\n' '{"sandbox":{"enabled":false}}' >"$settings"
prompt='Use the Read tool exactly twice and then stop. First read local-only-marker.txt. Then read remote-only-marker.txt. If a file is missing, say RW_C4_READ_MISS for that file. Do not use Bash. Do not write or edit. Do not print the environment, tokens, or home directory.'
out="${RW_RAW}/c4-claude.out"
err="${RW_RAW}/c4-claude.err"
(
  cd "$proj" || exit 97
  CLAUDE_CODE_OAUTH_TOKEN=$(<"$token_file") \
    CLAUDE_CODE_SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    claude -p \
      --permission-mode bypassPermissions \
      --dangerously-skip-permissions \
      --allowedTools Read \
      --disallowedTools "Bash,Edit,Write,NotebookEdit,Grep,Glob" \
      --effort low \
      --settings "$settings" \
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
exec_reject_secrets "$out"
exec_reject_secrets "$err"
auth_refused=0
if grep -E -i -q 'failed to authenticate|access token is invalid' "$out" "$err"; then
  auth_refused=1
  note "auth: 401 invalid"
elif grep -E -i -q 'usage limit|rate limit|quota exceeded|hit your limit|try again at' "$out" "$err"; then
  auth_refused=1
  note "auth: limit"
fi
if [[ "$auth_refused" -eq 1 ]]; then
  note "read: not-observed"
  note "persistent shell: not-observed"
  note "mcp: not-observed"
  note "The named account refused the session. No further account was tried."
  note "RESULT: partial account-refused"
  coverage_finish c4
fi
if grep -F -q 'rw-local-only-marker' "$out"; then
  pass "Read saw the provider-only file"
  note "read: local"
else
  fail "Read did not see the provider-only file"
  note "read: missing"
fi
if grep -F -q 'rw-remote-only-marker' "$out"; then
  fail "Read saw the remote-only file"
  note "read_remote: visible"
else
  pass "Read did not see the remote-only file"
  note "read_remote: absent"
fi
if grep -F -q 'RW_C4_READ_MISS' "$out"; then
  pass "Read reported the remote-only file missing"
else
  note "read_miss_phrase: absent"
fi
note "RESULT: see passes"
coverage_finish c4
