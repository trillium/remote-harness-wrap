#!/bin/bash
# B9. rw down removes the project it created and leaves no mount.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

own_remote="/tmp/rw-bd-down${RANDOM}${RANDOM}"
own_local=$(mktemp -d /tmp/rw-bd-down-local.XXXXXX)
own_state=$(mktemp -d /tmp/rw-bd-down-state.XXXXXX)
run_out=$(mktemp "${TMPDIR:-/tmp}/rw-bd-down-out.XXXXXX")

set +e
RW_STATE="$own_state" RW_BUILD="$RW_RAW/build" "$RW_BIN" run \
  --remote "$RW_SSH_TARGET" \
  --project "$own_remote" \
  --local "$own_local" \
  -- /usr/bin/true >"$run_out" 2>&1
run_rc=$?
set -e
note "run_rc=$run_rc"
if [[ $run_rc -eq 0 ]]; then
  pass "rw run exited 0"
else
  fail "rw run failed"
fi

set +e
RW_STATE="$own_state" "$RW_BIN" down >"$run_out" 2>&1
down_rc=$?
set -e
note "down_rc=$down_rc"
if [[ $down_rc -eq 0 ]]; then
  pass "rw down exited 0"
else
  fail "rw down failed"
fi
if grep -q 'project=gone' "$run_out"; then
  pass "remote project is gone"
else
  fail "remote project was not reported gone"
fi
if grep -q 'host_mount=gone' "$run_out"; then
  pass "no rw mount remains"
else
  fail "rw mount still reported"
fi
if proof_ssh "if [ -e $(printf '%q' "$own_remote") ]; then echo present; else echo gone; fi" | grep -q gone; then
  pass "remote scratch path is gone"
else
  fail "remote scratch path is still present"
  proof_ssh "rm -rf -- $(printf '%q' "$own_remote")" >/dev/null 2>&1 || true
fi
if mount | grep -E 'rw-bd|rw-pkg' >/dev/null; then
  fail "a matching mount is still listed"
else
  pass "mount table has no rw scratch"
fi
rm -rf "$own_local" "$own_state" "$run_out"
proof_finish b9
