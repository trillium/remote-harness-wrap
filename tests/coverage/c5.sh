#!/bin/bash
# C5. OpenCode free model, shell tool on the remote.
# C6 shell half: that same command reads a file that exists only on the remote.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v opencode >/dev/null 2>&1; then
  fail "opencode is not on PATH"
  coverage_finish c5
fi
note "opencode: $(opencode --version 2>/dev/null | head -1)"
note "model: opencode/big-pickle"

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj") && printf 'rw-remote-only-marker\n' > $(printf '%q' "$remote_proj/remote-only-marker.txt")" \
  || fail "could not place the remote marker"

raw_log="${RW_RAW}/c5-argv.log"
: >"$raw_log"
out="${RW_RAW}/c5-opencode.out"
err="${RW_RAW}/c5-opencode.err"
prompt='Use the bash tool exactly once and then stop. The command is: hostname; echo RW_C5_OK; cat remote-only-marker.txt. Do not use any other tool. Do not print the environment, tokens, or home directory.'
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
if grep -F -q '[-c]' "$raw_log"; then
  pass "OpenCode invoked the shell wrapper"
else
  fail "OpenCode did not invoke the shell wrapper"
fi
# OpenCode writes the tool transcript to stderr and the prompt into the argv log.
# The argv log is proof the wrapper was called, not proof the command ran.
if grep -F -q 'rw-remote-only-marker' "$out" || grep -F -q 'rw-remote-only-marker' "$err"; then
  pass "shell command read the remote-only file"
  note "c6_shell: remote-only file visible to the shell"
else
  fail "shell command did not read the remote-only file"
  note "c6_shell: marker missing"
fi
if grep -F -q 'RW_C5_OK' "$out" || grep -F -q 'RW_C5_OK' "$err"; then
  pass "free-model turn printed the marker command's output"
else
  fail "free-model turn did not print the marker command's output"
fi
seen_remote=0
if grep -F -q "$RW_REMOTE_HOSTNAME" "$out" || grep -F -q "$RW_REMOTE_HOSTNAME" "$err"; then
  seen_remote=1
fi
if [[ "$seen_remote" -eq 1 ]]; then
  pass "shell printed the remote hostname"
  note "hosts_differ: yes"
else
  fail "shell did not print the remote hostname"
  note "hosts_differ: no"
fi
if [[ -e "$proj/remote-only-marker.txt" ]]; then
  fail "remote marker appeared on the provider"
else
  pass "remote marker stayed off the provider"
fi
note "RESULT: see passes"
coverage_finish c5
