#!/bin/bash
# A7. Cancelling the local command kills the remote process.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

pidfile="${RW_LOCAL_ROOT}/proj/sleep.pid"
remote_pidfile="${RW_REMOTE_ROOT}/proj/sleep.pid"
exec_ssh "rm -f $(printf '%q' "$remote_pidfile")" >/dev/null 2>&1 || true
script="echo \$\$ > ${pidfile}; exec sleep 600"

a7_cleanup() {
  local pid="${A7_PID:-}"
  [[ -n "$pid" ]] || return 0
  exec_ssh "kill -KILL -${pid} 2>/dev/null || kill -KILL ${pid} 2>/dev/null || true" >/dev/null 2>&1 || true
}
export RW_EXTRA_CLEAN="a7_cleanup"

set -m
(
  cd "$RW_LOCAL_ROOT/proj" || exit 97
  export RW_SSH_TARGET RW_PATH_MAP RW_CONTROL_PATH RW_CONTROL_PERSIST
  export RW_TRANSPORT=broker
  export RW_ALLOW_VARS="${RW_ALLOW_VARS:-}"
  unset RW_LOG
  exec "$RW_WRAP" -c -l "$script"
) >"${RW_RAW}/a7-out.txt" 2>"${RW_RAW}/a7-err.txt" &
wpid=$!
set +m

A7_PID=""
i=0
while [[ "$i" -lt 40 ]]; do
  body=$(exec_ssh "cat $(printf '%q' "$remote_pidfile") 2>/dev/null" || true)
  body=$(printf '%s' "$body" | tr -cd '0-9')
  if [[ -n "$body" ]]; then
    A7_PID="$body"
    break
  fi
  sleep 0.25
  i=$((i + 1))
done

if [[ -z "$A7_PID" ]]; then
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  fail "remote pid file never appeared"
  exec_finish a7
fi
pass "remote sleep pid observed"

kill -INT -"$wpid" 2>/dev/null || kill -INT "$wpid" 2>/dev/null || true
i=0
while [[ "$i" -lt 40 ]]; do
  if ! kill -0 "$wpid" 2>/dev/null; then
    break
  fi
  sleep 0.25
  i=$((i + 1))
done
if kill -0 "$wpid" 2>/dev/null; then
  kill -KILL "$wpid" 2>/dev/null || true
  fail "wrapper still running after interrupt"
else
  pass "wrapper exited after interrupt"
fi

sleep 0.5
if exec_ssh "kill -0 ${A7_PID} 2>/dev/null"; then
  fail "remote process ${A7_PID} still alive"
else
  pass "remote process is gone"
fi
A7_PID=""
exec_finish a7
