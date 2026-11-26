#!/bin/bash
# A2. Stdout, stderr, and the exit code reach the harness unchanged.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

run_case() {
  local name="$1" script="$2" want="$3"
  local lout lerr rout rerr lrc rrc
  lout=$(mktemp "${TMPDIR:-/tmp}/rw-lout.XXXXXX")
  lerr=$(mktemp "${TMPDIR:-/tmp}/rw-lerr.XXXXXX")
  rout=$(mktemp "${TMPDIR:-/tmp}/rw-rout.XXXXXX")
  rerr=$(mktemp "${TMPDIR:-/tmp}/rw-rerr.XXXXXX")
  (
    cd "$RW_LOCAL_ROOT/proj" || exit 97
    /bin/bash --noprofile --norc -c "$script"
  ) >"$lout" 2>"$lerr"
  lrc=$?
  exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"$rout" 2>"$rerr"
  rrc=$?
  if [[ "$lrc" -eq "$want" && "$rrc" -eq "$want" ]]; then
    pass "${name}: exit ${want}"
  else
    fail "${name}: exit local=${lrc} wrapped=${rrc} want=${want}"
  fi
  if cmp -s "$lout" "$rout"; then
    pass "${name}: stdout matches a local run"
  else
    fail "${name}: stdout differs"
    diff -u "$lout" "$rout" | head -20 | tee -a "$NOTES" || true
  fi
  if cmp -s "$lerr" "$rerr"; then
    pass "${name}: stderr matches a local run"
  else
    fail "${name}: stderr differs"
    diff -u "$lerr" "$rerr" | head -20 | tee -a "$NOTES" || true
  fi
  rm -f "$lout" "$lerr" "$rout" "$rerr"
}

run_case "exit 0" 'printf "out-zero\n"; printf "err-zero\n" >&2; exit 0' 0
run_case "exit 1" 'printf "out-one\n"; printf "err-one\n" >&2; exit 1' 1
run_case "exit 7" 'printf "out-seven\n"; printf "err-seven\n" >&2; exit 7' 7

exec_finish a2
