#!/bin/bash
# Run exec-plane assertions against one target.
#
#   tests/exec/run.sh
#   tests/exec/run.sh --target localhost
#   RW_SSH_TARGET=localhost RW_PATH_MAP='/tmp/local|/tmp/remote' tests/exec/run.sh A2 A5
#
# With no map, scratch directories are created and removed.
# Logs are written under evidence/exec/ using a target placeholder, not a hostname.
# A1 reads the credential path from RW_TOKEN_FILE and never prints that file.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

exec_parse_args "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-localhost}"
export RW_SSH_TARGET
RW_KEEP_SESSION=1
export RW_KEEP_SESSION

if [[ -z "${RW_PATH_MAP:-}" ]]; then
  RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-exec-local.XXXXXX)
  if [[ "$RW_SSH_TARGET" == localhost || "$RW_SSH_TARGET" == 127.0.0.1 ]]; then
    RW_REMOTE_ROOT=$(mktemp -d /tmp/rw-exec-remote.XXXXXX)
  else
    RW_REMOTE_ROOT="/tmp/rw-exec-remote.${RANDOM}${RANDOM}"
  fi
  RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
  RW_OWN_MAP=1
else
  first="${RW_PATH_MAP%%;*}"
  RW_LOCAL_ROOT="${first%%|*}"
  RW_REMOTE_ROOT="${first#*|}"
  RW_OWN_MAP=0
fi
export RW_PATH_MAP RW_LOCAL_ROOT RW_REMOTE_ROOT
# This runner owns evidence/exec. A parent proof must not redirect it.
case "${RW_EVIDENCE:-}" in
  */evidence/exec) ;;
  *) RW_EVIDENCE="$(exec_root)/evidence/exec" ;;
esac
RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-exec-proof-raw}"
export RW_EVIDENCE RW_RAW
mkdir -p "$RW_LOCAL_ROOT/proj" "$RW_EVIDENCE" "$RW_RAW"
exec_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT/proj")" || {
  printf 'run: could not prepare remote scratch\n' >&2
  exit 1
}

ids=()
if [[ ${#EXEC_REST[@]} -eq 0 ]]; then
  if [[ "$RW_SSH_TARGET" == localhost || "$RW_SSH_TARGET" == 127.0.0.1 ]]; then
    ids=(1 2 3 5 9 7 8 6 4)
  else
    ids=(2 3 5 9 7 8 6 4)
  fi
else
  for item in "${EXEC_REST[@]}"; do
    ids+=("${item#A}")
    ids[${#ids[@]}-1]="${ids[${#ids[@]}-1]#a}"
  done
fi

runner_cleanup() {
  local rc=$?
  if [[ "${RW_OWN_MAP:-0}" == 1 ]]; then
    exec_wipe_scratch
  else
    exec_stop_broker
    exec_master_exit
  fi
  exit "$rc"
}
trap runner_cleanup EXIT

label=$(exec_label)
fail_n=0
pass_n=0
summary="${RW_RAW}/summary-${label}.txt"
: >"$summary"
printf 'label: %s\nwhen: %s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$summary"

for id in "${ids[@]}"; do
  script="${HERE}/a${id}.sh"
  if [[ ! -x "$script" && ! -f "$script" ]]; then
    printf 'MISSING a%s\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
    continue
  fi
  if "$script" --target "$RW_SSH_TARGET" --map "$RW_PATH_MAP" --evidence "$RW_EVIDENCE" --label "$label"; then
    printf 'a%s PASS\n' "$id" | tee -a "$summary"
    pass_n=$((pass_n + 1))
  else
    printf 'a%s FAIL\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
  fi
done

printf 'summary pass=%s fail=%s\n' "$pass_n" "$fail_n" | tee -a "$summary"
exec_redact_file "$summary" "${RW_EVIDENCE}/${label}-summary.log"
if [[ "$fail_n" -gt 0 ]]; then
  exit 1
fi
exit 0
