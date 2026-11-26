#!/bin/bash
# B8. Cutting the ssh read makes it fail within 10 seconds.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"
note "bound_seconds=10"

out=$(mktemp "${TMPDIR:-/tmp}/rw-bd-cut.XXXXXX")
canary="$RW_LOCAL_ROOT/canary.txt"
printf 'untouched\n' >"$canary"
start=$(date +%s)
ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=8 \
  -o LogLevel=ERROR \
  -T \
  "$RW_SSH_TARGET" \
  "python3 -c 'import sys,time; sys.stdout.buffer.write(b\"x\"*4096); sys.stdout.flush(); time.sleep(30)'" \
  >"$out" &
pid=$!
sleep 0.6
if [[ ! -s "$out" ]]; then
  fail "read produced no bytes before the cut"
fi
kill -TERM "$pid" 2>/dev/null || true
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [[ $waited -ge 10 ]]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "read still running 10s after the cut"
    break
  fi
  sleep 1
  waited=$((waited + 1))
done
wait "$pid" 2>/dev/null || true
end=$(date +%s)
note "cut_wait_seconds=$waited elapsed=$((end - start))"
if [[ $waited -lt 10 ]]; then
  pass "read ended within 10s of the cut"
fi
body=$(cat "$canary")
body=${body%$'\n'}
if [[ "$body" == untouched ]]; then
  pass "local canary was not rewritten"
else
  fail "local canary changed"
fi
rm -f "$out"
proof_finish b8
