#!/bin/bash
# A12. A session's remote broker does not outlive the session.
# The wrapper leaves one detached broker shell on the remote per session so a
# background job survives its command. That broker has to go away when the
# session ends, including when the wrapper is killed and cannot clean up.
#
# Cases, each on its own broker directory and counted with ps on the remote:
#   clean     wrapper exits 0, nothing more is run: broker exits on idle.
#   sigterm   wrapper gets SIGTERM during a command: broker exits on idle.
#   sigkill   wrapper gets SIGKILL during a command: broker exits on idle,
#             but not while the job it started is still running.
#   live      commands keep arriving for longer than the idle time: the broker
#             stays and a background job stays reachable.
#   reap      `rw-bash --reap` stops the broker and its running job at once.
#   run       `rw run` removes its broker when the harness exits, when rw is
#             terminated, and `rw down` removes it after rw was killed.
#
# RW_BROKER_IDLE is set to 3 seconds here so the cases finish quickly. The
# default is 900.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

IDLE=3
export RW_BROKER_IDLE="$IDLE"
export RW_TRANSPORT=broker
TAG="a12-$$-${RANDOM}"
ROOTS=()
A12_PIDS=()
RUN_DIRS=()

root_for() { # root_for <case>
  local r="/tmp/rw-${TAG}-$1-broker"
  ROOTS+=("$r")
  printf '%s' "$r"
}

# Brokers for one root, counting the job subshells the broker forks too.
broker_procs() {
  local out
  [[ -n "$1" ]] || { printf '99'; return 0; }
  out=$(exec_ssh "ps -axo command | grep -c '[b]roker.sh $1'" 2>/dev/null || true)
  out=$(printf '%s' "$out" | tr -cd '0-9')
  printf '%s' "${out:-0}"
}

proc_alive() { # proc_alive <pid>
  local out
  out=$(exec_ssh "if kill -0 $1 2>/dev/null; then echo up; else echo down; fi" 2>/dev/null || true)
  [[ "$out" == *up* ]]
}

wait_gone() { # wait_gone <root> <seconds>
  local i=0
  while [[ "$i" -lt "$2" ]]; do
    [[ "$(broker_procs "$1")" == 0 ]] && return 0
    sleep 1
    i=$((i + 1))
  done
  [[ "$(broker_procs "$1")" == 0 ]]
}

wrap_bg() { # wrap_bg <root> <script> ; sets WPID
  local root="$1" script="$2"
  (
    cd "$RW_LOCAL_ROOT/proj" || exit 97
    export RW_BROKER_ROOT="$root"
    unset RW_LOG
    exec "$RW_WRAP" -c -l "$script"
  ) >/dev/null 2>&1 &
  WPID=$!
}

a12_cleanup() {
  local r pid
  for r in "${ROOTS[@]:-}"; do
    [[ -n "$r" ]] || continue
    RW_BROKER_ROOT="$r" RW_SSH_TARGET="$RW_SSH_TARGET" "$RW_WRAP" --reap >/dev/null 2>&1 || true
  done
  for r in "${RUN_DIRS[@]:-}"; do
    case "$r" in /tmp/rw-bd-"${TAG}"*) rm -rf -- "$r" "${r}.rw-manifest" ;; esac
    [[ -n "$r" ]] && exec_ssh "rm -rf -- $(printf '%q' "$r")" >/dev/null 2>&1 || true
  done
  for pid in "${A12_PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    exec_ssh "kill -KILL ${pid} 2>/dev/null || true" >/dev/null 2>&1 || true
  done
}
export RW_EXTRA_CLEAN="a12_cleanup"

wait_for_job_pid() { # wait_for_job_pid <root> ; prints the pid of the first job
  local root="$1" i=0 p=""
  while [[ "$i" -lt 40 ]]; do
    p=$(exec_ssh "cat $(printf '%q' "$root")/jobs/*/pid 2>/dev/null | head -1" 2>/dev/null || true)
    p=$(printf '%s' "$p" | tr -cd '0-9')
    [[ -n "$p" ]] && break
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s' "$p"
}

# --- clean exit, then nothing: idle exit ---
root=$(root_for clean)
wrap_bg "$root" 'echo clean-ok' && wait "$WPID"
if [[ "$(broker_procs "$root")" -ge 1 ]]; then
  note "clean: broker is running right after the command (expected, the next command reuses it)"
else
  fail "clean: broker was not running after the command"
fi
if wait_gone "$root" $((IDLE + 8)); then
  pass "clean: broker exited on its own after ${IDLE}s idle"
else
  fail "clean: broker still running ${IDLE}s idle plus 8s after the last command"
fi
left=$(exec_ssh "if [ -e $(printf '%q' "$root") ]; then echo present; else echo gone; fi" 2>/dev/null || true)
if [[ "$left" == *gone* ]]; then
  pass "clean: the idle exit also removed the broker directory"
else
  fail "clean: broker directory still present after the idle exit"
fi

# --- SIGTERM of the wrapper mid-command ---
root=$(root_for sigterm)
wrap_bg "$root" 'sleep 3; echo done'
tpid="$WPID"
jp=$(wait_for_job_pid "$root")
kill -TERM "$tpid" 2>/dev/null || true
wait "$tpid" 2>/dev/null
if [[ "$(broker_procs "$root")" -ge 1 ]]; then
  note "sigterm: broker survived the wrapper's SIGTERM (expected, one command is not the session)"
fi
if wait_gone "$root" $((IDLE + 12)); then
  pass "sigterm: broker exited on its own after the wrapper was terminated"
else
  fail "sigterm: broker still running after the wrapper was terminated"
fi

# --- SIGKILL of the wrapper mid-command ---
root=$(root_for sigkill)
wrap_bg "$root" 'sleep 6; echo done'
kpid="$WPID"
jp=$(wait_for_job_pid "$root")
kill -KILL "$kpid" 2>/dev/null || true
wait "$kpid" 2>/dev/null
sleep $((IDLE + 1))
if [[ -n "$jp" ]] && proc_alive "$jp" && [[ "$(broker_procs "$root")" -ge 1 ]]; then
  pass "sigkill: broker stayed while the job it started was still running"
elif [[ -z "$jp" ]]; then
  fail "sigkill: the job never started, so the case did not run"
else
  note "sigkill: job finished before the idle check; the running-job guard was not exercised"
fi
if wait_gone "$root" $((IDLE + 14)); then
  pass "sigkill: broker exited on its own after the wrapper was killed"
else
  fail "sigkill: broker still running after the wrapper was killed"
fi

# --- a live session keeps its broker and its background job ---
root=$(root_for live)
wrap_bg "$root" "sleep 300 </dev/null >/dev/null 2>&1 & echo \$! > ${RW_LOCAL_ROOT}/proj/live.pid" && wait "$WPID"
bgpid=$(exec_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/proj/live.pid")" 2>/dev/null | tr -cd '0-9')
[[ -n "$bgpid" ]] && A12_PIDS+=("$bgpid")
live_ok=1
n=0
while [[ "$n" -lt $((IDLE * 2 + 2)) ]]; do
  sleep 1
  wrap_bg "$root" "kill -0 \$(cat ${RW_LOCAL_ROOT}/proj/live.pid) && echo up" && wait "$WPID" || live_ok=0
  n=$((n + 1))
done
if [[ "$live_ok" == 1 && "$(broker_procs "$root")" -ge 1 ]] && proc_alive "${bgpid:-0}"; then
  pass "live: broker and background job both stayed through $((IDLE * 2 + 2))s of commands (idle limit ${IDLE}s)"
else
  fail "live: broker or background job was lost while commands were still arriving"
fi
if wait_gone "$root" $((IDLE + 8)); then
  pass "live: after the last command the broker exited on its own"
else
  fail "live: broker still running after the last command"
fi
if [[ -n "$bgpid" ]] && proc_alive "$bgpid"; then
  pass "live: the background process itself was not killed by the broker exiting"
else
  note "live: background process was gone after the broker exited"
fi

# --- explicit reap ---
root=$(root_for reap)
wrap_bg "$root" 'sleep 120; echo done'
rpid="$WPID"
jp=$(wait_for_job_pid "$root")
kill -KILL "$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null
[[ -n "$jp" ]] && A12_PIDS+=("$jp")
RW_BROKER_ROOT="$root" "$RW_WRAP" --reap
sleep 1
left=$(exec_ssh "if [ -e $(printf '%q' "$root") ]; then echo present; else echo gone; fi" 2>/dev/null || true)
if [[ "$(broker_procs "$root")" == 0 && "$left" == *gone* ]] && [[ -n "$jp" ]] && ! proc_alive "$jp"; then
  pass "reap: --reap stopped the broker and its running job and removed the directory"
else
  fail "reap: broker=$(broker_procs "$root") dir=${left} job=${jp:-none}"
fi

# --- rw run and rw down ---
RW_BIN="$(exec_root)/src/rw"
run_case() { # run_case <name> <fake-body> <how>
  local name="$1" body="$2" how="$3" tmp fake proj lcl state
  tmp=$(mktemp -d "/tmp/rw-bd-${TAG}-${name}.XXXXXX")
  # rw only replaces a scratch directory directly under /tmp.
  proj="/tmp/rw-bd-${TAG}-${name}-r"
  lcl="/tmp/rw-bd-${TAG}-${name}-l"
  RUN_DIRS+=("$tmp" "$lcl" "$proj")
  state="$tmp/state"
  fake="$tmp/bin/claude"
  mkdir -p "$tmp/bin" "$lcl"
  printf '#!/bin/bash\n%s\n' "$body" >"$fake"
  chmod +x "$fake"
  (
    export RW_STATE="$state" RW_CONTROL_PATH="/tmp/rw-bd-${TAG}-%C" RW_BUILD="$tmp/build"
    exec "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$proj" --local "$lcl" -- "$fake"
  ) >"$tmp/run.out" 2>&1 &
  RUNPID=$!
  local i=0 broot=""
  while [[ "$i" -lt 60 ]]; do
    broot=$(sed -n 's/^BROKER_ROOT=//p' "$state/current.env" 2>/dev/null | head -1)
    [[ -n "$broot" && "$(broker_procs "$broot")" -ge 1 ]] && break
    sleep 0.25
    i=$((i + 1))
  done
  RUN_BROOT="$broot"
  RUN_TMP="$tmp"
  RUN_STATE="$state"
  ROOTS+=("$broot")
  case "$how" in
    wait) wait "$RUNPID" ;;
    term) kill -TERM "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null ;;
    kill-down)
      kill -KILL "$RUNPID" 2>/dev/null
      wait "$RUNPID" 2>/dev/null
      ;;
  esac
}

fake_cmd='"$CLAUDE_CODE_SHELL" -c "echo from-run" </dev/null; '
run_case exit "${fake_cmd}"'sleep 1' wait
if [[ -n "$RUN_BROOT" && "$(broker_procs "$RUN_BROOT")" == 0 ]]; then
  pass "run: rw run removed its broker when the harness exited"
else
  fail "run: broker ${RUN_BROOT:-unknown} still present after the harness exited"
fi

run_case term "${fake_cmd}"'sleep 60' term
if [[ -n "$RUN_BROOT" ]] && wait_gone "$RUN_BROOT" 6; then
  pass "run: rw run removed its broker when it was terminated"
else
  fail "run: broker ${RUN_BROOT:-unknown} still present after rw run was terminated"
fi

run_case killdown "${fake_cmd}"'sleep 60' kill-down
if [[ "$(broker_procs "$RUN_BROOT")" -ge 1 ]]; then
  note "run: broker survived the SIGKILL of rw run (expected, nothing could clean up)"
fi
RW_STATE="$RUN_STATE" RW_CONTROL_PATH="/tmp/rw-bd-${TAG}-%C" "$RW_BIN" down >"$RUN_TMP/down.out" 2>&1
if [[ -n "$RUN_BROOT" ]] && wait_gone "$RUN_BROOT" 6 && grep -q 'broker=reaped' "$RUN_TMP/down.out"; then
  pass "run: rw down removed the broker of a killed rw run"
else
  fail "run: broker ${RUN_BROOT:-unknown} still present after rw down"
fi

exec_finish a12
