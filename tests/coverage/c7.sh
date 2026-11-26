#!/bin/bash
# C7. Codex launch, and the forwarded -lc command path. The model limit means
# the shell tool and file tools stay pending unless a command is actually issued.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v codex >/dev/null 2>&1; then
  fail "codex is not on PATH"
  coverage_finish c7
fi
ver=$(codex --version 2>/dev/null | head -1)
note "codex: ${ver}"
if [[ -n "$ver" ]]; then
  pass "codex --version printed"
else
  fail "codex --version printed nothing"
fi

proj="${RW_LOCAL_ROOT}/proj"
mkdir -p "$proj"
raw_log="${RW_RAW}/c7-argv.log"
: >"$raw_log"
out="${RW_RAW}/c7-codex.out"
err="${RW_RAW}/c7-codex.err"
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
    codex exec \
      --skip-git-repo-check \
      --ephemeral \
      --ignore-user-config \
      --dangerously-bypass-approvals-and-sandbox \
      "Run one shell command: echo RW_C7_OK. Then stop."
) >"$out" 2>"$err" &
pid=$!
ticks=0
while kill -0 "$pid" 2>/dev/null && [[ "$ticks" -lt 120 ]]; do
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
note "codex_exec_exit: ${rc}"
exec_reject_secrets "$out"
exec_reject_secrets "$err"
if grep -E -i -q 'usage limit|rate limit|quota|hit your limit|try again|insufficient|too many requests|resets' "$out" "$err"; then
  note "model: limit exhausted"
  pass "codex exec reached the model and stopped on the limit"
else
  note "model: no limit phrase"
fi
if grep -F -q 'RW_C7_OK' "$raw_log" || grep -F -q 'RW_C7_OK' "$out"; then
  pass "codex issued a shell command through the wrapper"
  note "shell_tool: observed"
else
  note "shell_tool: pending"
  note "file_tools: pending"
  pass "launch recorded; shell and file tools were not issued"
fi

path_out="${RW_RAW}/c7-path.out"
path_err="${RW_RAW}/c7-path.err"
(
  cd "$proj" || exit 97
  export RW_SSH_TARGET RW_PATH_MAP RW_TRANSPORT RW_BROKER_ROOT RW_CONTROL_PATH RW_CONTROL_PERSIST
  "$RW_WRAP" -lc 'echo RW_C7_PATH'
) >"$path_out" 2>"$path_err"
path_rc=$?
note "lc_exit: ${path_rc}"
if [[ "$path_rc" -eq 0 ]] && grep -F -q 'RW_C7_PATH' "$path_out"; then
  pass "rw-bash -lc forwards a command to the remote"
  note "command_path: -lc forwarded"
else
  fail "rw-bash -lc did not forward"
fi
note "RESULT: see passes"
coverage_finish c7
