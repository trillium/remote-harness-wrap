#!/bin/bash
# Counts broker shells on the remote before and after one wrapped run and its
# teardown, so a leak shows as a number, not as a claim.
#
#   RW_SSH_TARGET=<ssh-host> tests/exec/broker-count.sh
#
# One `rw run` starts a stand-in harness that runs one wrapped command, then
# exits. `rw down` follows. Shells are counted with ps on the remote, the same
# way A12 counts them: command lines that name a broker.sh. Two numbers are
# kept: shells under this run's own broker directory (must end at 0), and every
# broker shell on the remote (must not grow; shells older than this run belong
# to other sessions and are only reported).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

TAG="bc-$$-${RANDOM}"
RUN_DIRS=()

count_all() {
  local out
  out=$(exec_ssh "ps -axo command | grep -c '[b]roker.sh'" 2>/dev/null || true)
  out=$(printf '%s' "$out" | tr -cd '0-9')
  printf '%s' "${out:-0}"
}
count_root() { # count_root <broker-root>
  local out
  [[ -n "$1" ]] || { printf '0'; return 0; }
  out=$(exec_ssh "ps -axo command | grep -c '[b]roker.sh $1'" 2>/dev/null || true)
  out=$(printf '%s' "$out" | tr -cd '0-9')
  printf '%s' "${out:-0}"
}
bc_cleanup() {
  local r
  for r in "${RUN_DIRS[@]:-}"; do
    case "$r" in /tmp/rw-bd-"${TAG}"*) rm -rf -- "$r" "${r}.rw-manifest" ;; esac
    [[ -n "$r" ]] && exec_ssh "rm -rf -- $(printf '%q' "$r")" >/dev/null 2>&1 || true
  done
}
export RW_EXTRA_CLEAN="bc_cleanup"

RW_BIN="$(exec_root)/src/rw"
tmp=$(mktemp -d "/tmp/rw-bd-${TAG}.XXXXXX")
proj="/tmp/rw-bd-${TAG}-r"
lcl="/tmp/rw-bd-${TAG}-l"
RUN_DIRS+=("$tmp" "$lcl" "$proj")
state="$tmp/state"
mkdir -p "$tmp/bin" "$lcl"
printf '#!/bin/bash\n%s\n' '"$CLAUDE_CODE_SHELL" -c "echo from-run" </dev/null; sleep 1' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"

before_all=$(count_all)
note "before: broker shells on the remote, all sessions: ${before_all}"

(
  export RW_STATE="$state" RW_CONTROL_PATH="/tmp/rw-bd-${TAG}-%C" RW_BUILD="$tmp/build"
  exec "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$proj" --local "$lcl" -- "$tmp/bin/claude"
) >"$tmp/run.out" 2>&1
run_rc=$?
broot=$(sed -n 's/^BROKER_ROOT=//p' "$state/current.env" 2>/dev/null | head -1)
note "run: rw run exited ${run_rc}; broker root recorded: $([[ -n "$broot" ]] && echo yes || echo no)"
if grep -q from-run "$tmp/run.out" 2>/dev/null; then
  note "run: the wrapped command ran on the remote"
else
  note "run: wrapped command output not seen"
fi

mid_root=$(count_root "$broot")
note "after run, before down: shells under this run's broker directory: ${mid_root}"

RW_STATE="$state" RW_CONTROL_PATH="/tmp/rw-bd-${TAG}-%C" "$RW_BIN" down >"$tmp/down.out" 2>&1
note "down: rw down exited $?"
sleep 2
after_root=$(count_root "$broot")
after_all=$(count_all)
note "after: shells under this run's broker directory: ${after_root}"
note "after: broker shells on the remote, all sessions: ${after_all}"
left=$(exec_ssh "if [ -e $(printf '%q' "${broot:-/nonexistent}") ]; then echo present; else echo gone; fi" 2>/dev/null || true)
note "after: this run's broker directory: ${left}"

if [[ -n "$broot" && "$after_root" == 0 && "$left" == *gone* ]]; then
  pass "this run left no broker shell and no broker directory (${mid_root} before down, ${after_root} after)"
else
  fail "this run's broker remained: shells=${after_root} dir=${left} root=${broot:-unknown}"
fi
if [[ "$after_all" -le "$before_all" ]]; then
  pass "total broker shells did not grow (${before_all} before, ${after_all} after)"
else
  fail "total broker shells grew from ${before_all} to ${after_all}"
fi
exec_finish broker-count
