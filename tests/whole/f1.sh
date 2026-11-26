#!/bin/bash
# F1. One command starts a wrapped harness session. One command stops it
# and removes the scratch tree. F3 records the harness checksum before and
# after that session.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/proof.sh
. "$HERE/../lib/proof.sh"
export RW_EVIDENCE_PLANE=whole
proof_prepare "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-}"
[[ -n "$RW_SSH_TARGET" ]] || {
  note "missing ssh target"
  FAILS=$((FAILS + 1))
  proof_finish f1
}

harness=""
harness_bin=""
if command -v claude >/dev/null 2>&1; then
  harness=claude
  harness_bin=$(command -v claude)
elif command -v opencode >/dev/null 2>&1; then
  harness=opencode
  harness_bin=$(command -v opencode)
else
  fail "no harness on PATH"
  proof_finish f1
fi
note "harness=${harness}"
sum_before=$(shasum -a 256 "$harness_bin" | awk '{print $1}')
note "checksum_before=${sum_before}"

nonce="f1${RANDOM}${RANDOM}"
local_dir=$(mktemp -d "/tmp/rw-bd-local.XXXXXX")
remote_dir="/tmp/rw-bd-${nonce}"
state=$(mktemp -d "/tmp/rw-bd-state.XXXXXX")
export RW_STATE="$state"
export RW_CONTROL_PATH="/tmp/rw-f1-${nonce}-%C"

cleanup_left() {
  RW_STATE="$state" "$RW_BIN" down >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR -T "$RW_SSH_TARGET" \
    "rm -rf -- $(printf '%q' "$remote_dir")" >/dev/null 2>&1 || true
  rm -rf "$local_dir" "${local_dir}.rw-manifest" "$state"
}
trap cleanup_left EXIT

prompt='Use the Bash tool once and then stop. The command is: echo F1_OK; sleep 25. Do not read or write files. Do not print the environment or the home directory.'
run_log="${RW_RAW}/f1-run.out"
if [[ "$harness" == claude ]]; then
  RW_STATE="$state" RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$remote_dir" --local "$local_dir" -- \
    "$harness_bin" -p --model haiku --permission-mode bypassPermissions \
    --dangerously-skip-permissions --allowedTools Bash --effort low \
    "$prompt" >"$run_log" 2>"${RW_RAW}/f1-run.err" &
else
  RW_STATE="$state" RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$remote_dir" --local "$local_dir" -- \
    "$harness_bin" --pure run -m opencode/big-pickle --auto "$prompt" \
    >"$run_log" 2>"${RW_RAW}/f1-run.err" &
fi
run_pid=$!
note "start_command=rw-run"
# Give the wrapper time to record state, then stop it while it is alive.
lived=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  if [[ -f "$state/current.env" ]]; then
    lived=1
    break
  fi
  if ! kill -0 "$run_pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if kill -0 "$run_pid" 2>/dev/null; then
  note "session=running-at-stop"
else
  note "session=exited-before-stop"
fi
down_out=$(RW_STATE="$state" "$RW_BIN" down 2>&1 || true)
note "stop_command=rw-down"
printf '%s\n' "$down_out" | sed 's/[0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}/redacted-ip/g' >>"$NOTES"
sleep 0.5
if kill -0 "$run_pid" 2>/dev/null; then
  fail "the wrapped process was still running after stop"
  kill -TERM "$run_pid" 2>/dev/null || true
  wait "$run_pid" 2>/dev/null || true
else
  pass "the wrapped process is not running after stop"
  wait "$run_pid" 2>/dev/null || true
fi
if printf '%s\n' "$down_out" | grep -F -q 'project=gone'; then
  pass "stop removed the remote project"
elif printf '%s\n' "$down_out" | grep -F -q 'project=not-created-by-rw'; then
  fail "stop did not own the remote project"
else
  fail "stop did not report the remote project gone"
fi
if printf '%s\n' "$down_out" | grep -F -q 'state=gone'; then
  pass "stop removed the local state"
else
  fail "stop left local state"
fi
if printf '%s\n' "$down_out" | grep -F -q 'host_mount=gone'; then
  pass "stop left nothing mounted"
else
  fail "stop did not report mounts clear"
fi
if proof_ssh "if [ -e $(printf '%q' "$remote_dir") ]; then echo present; else echo gone; fi" | grep -q gone; then
  pass "remote project directory is gone"
else
  fail "remote project directory still exists"
fi

sum_after=$(shasum -a 256 "$harness_bin" | awk '{print $1}')
note "checksum_after=${sum_after}"
if [[ "$sum_before" == "$sum_after" && -n "$sum_before" ]]; then
  pass "harness checksum is unchanged"
  note "checksum_match=yes"
else
  fail "harness checksum changed"
  note "checksum_match=no"
fi
if [[ "$lived" -eq 1 ]]; then
  pass "one start command created a wrapped session"
else
  fail "the start command did not record a session"
fi

# F3 evidence is the checksum lines from this same session.
f3_raw="${RW_RAW}/f3-from-f1.log"
{
  printf 'id: f3\n'
  printf 'label: %s\n' "$(proof_label)"
  printf 'when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'harness: %s\n' "$harness"
  printf 'checksum_before: %s\n' "$sum_before"
  printf 'checksum_after: %s\n' "$sum_after"
  if [[ "$sum_before" == "$sum_after" && -n "$sum_before" ]]; then
    printf 'passes: 1\nfails: 0\n'
    printf 'PASS: harness checksum is unchanged\n'
  else
    printf 'passes: 0\nfails: 1\n'
    printf 'FAIL: harness checksum changed\n'
  fi
} >"$f3_raw"
proof_redact_file "$f3_raw" "${RW_EVIDENCE}/$(proof_label)-f3.log"
proof_reject_secrets "${RW_EVIDENCE}/$(proof_label)-f3.log"
proof_leak_check "${RW_EVIDENCE}/$(proof_label)-f3.log"
proof_finish f1
