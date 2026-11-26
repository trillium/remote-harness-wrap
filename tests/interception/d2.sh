#!/bin/bash
# D2. The forwarder does not forward ssh, dyld, or itself into a loop.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
intercept_begin "$@"
intercept_build
RW_FWD_LOG="$RW_RAW/d2-forward.log"
export RW_FWD_LOG
: >"$RW_FWD_LOG"

intercept_probe /usr/bin/ssh -V >/dev/null 2>&1 || true
intercept_probe /usr/lib/dyld >/dev/null 2>&1 || true
if grep -q 'decision=pass-exempt path=/usr/bin/ssh' "$RW_FWD_LOG"; then
  pass "ssh stays local"
else
  fail "ssh was not exempt"
fi
if grep -q 'decision=pass-exempt path=/usr/lib/dyld' "$RW_FWD_LOG"; then
  pass "dyld stays local"
else
  fail "dyld was not exempt"
fi

: >"$RW_FWD_LOG"
DYLD_INSERT_LIBRARIES="$RW_DYLIB" \
  RW_SSH_TARGET="$RW_SSH_TARGET" \
  RW_LOG="$RW_FWD_LOG" \
  RW_ENV_MODE=reduced \
  RW_CONTROL_PATH="$RW_CONTROL_PATH" \
  RW_GUEST_ROOT="$RW_LOCAL_ROOT" \
  RW_REMOTE_ROOT="$RW_REMOTE_ROOT" \
  "$RW_PROBE" /bin/bash -c "printf \$\$ > $(printf '%q' "$RW_REMOTE_ROOT/sleeper.pid"); exec sleep 30" &
probe_pid=$!
sleep 0.8
child=$(pgrep -P "$probe_pid" | head -n 1 || true)
child_comm=""
if [[ -n "$child" ]]; then
  child_comm=$(ps -p "$child" -o comm= | awk '{print $NF}')
  child_comm=${child_comm##*/}
fi
note "child_comm=${child_comm:-none}"
if [[ "$child_comm" == ssh || "$child_comm" == */ssh ]]; then
  pass "the forwarded child is a single ssh"
else
  fail "the forwarded child is not ssh"
fi
if [[ -n "$child" ]]; then
  grands=$(pgrep -P "$child" | wc -l | tr -d ' ')
  if [[ "$grands" == 0 ]]; then
    pass "ssh has no local child"
  else
    fail "ssh spawned a local child"
  fi
  if ps eww -p "$child" | tr ' ' '\n' | grep -q '^DYLD_INSERT_LIBRARIES='; then
    fail "ssh still carries DYLD_INSERT_LIBRARIES"
  else
    pass "ssh does not carry DYLD_INSERT_LIBRARIES"
  fi
fi
loaded=$(grep 'decision=loaded' "$RW_FWD_LOG" | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
note "loaded_pids=$loaded"
if [[ "$loaded" == 1 ]]; then
  pass "the forwarder loaded in one process"
else
  fail "the forwarder loaded in $loaded processes"
fi
kill -TERM "$probe_pid" 2>/dev/null || true
if [[ -n "$child" ]]; then
  kill -TERM "$child" 2>/dev/null || true
fi
wait "$probe_pid" 2>/dev/null || true
spid=$(proof_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/sleeper.pid") 2>/dev/null" || true)
spid=$(printf '%s' "$spid" | tr -d '\r\n')
if [[ -n "$spid" ]]; then
  proof_ssh "kill $(printf '%q' "$spid") 2>/dev/null || true" || true
fi
proof_ssh "rm -f $(printf '%q' "$RW_REMOTE_ROOT/sleeper.pid")" >/dev/null 2>&1 || true
proof_finish d2
