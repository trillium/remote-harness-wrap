#!/bin/bash
# Run file-plane assertions against one ssh target.
#
#   RW_SSH_TARGET=<host> RW_LABEL=remote-linux tests/file-plane/run.sh
#   tests/file-plane/run.sh --target <host> --label remote-linux B2 B3
#
# B1 is the provider mount check: tests/file-plane/b1.sh
# Logs land in evidence/file-plane/. Scratch directories are removed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

proof_parse_args "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-}"
[[ -n "$RW_SSH_TARGET" ]] || {
  printf 'run: set RW_SSH_TARGET or pass --target\n' >&2
  exit 2
}
export RW_SSH_TARGET
RW_KEEP_SESSION=1
export RW_KEEP_SESSION
RW_ROOT=$(proof_root)
# This runner owns evidence/file-plane. A parent proof must not redirect it.
case "${RW_EVIDENCE:-}" in
  */evidence/file-plane) ;;
  *) RW_EVIDENCE="$RW_ROOT/evidence/file-plane" ;;
esac
RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-bd-raw}"
export RW_EVIDENCE RW_RAW

if [[ -z "${RW_PATH_MAP:-}" ]]; then
  RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-bd-local.XXXXXX)
  RW_LOCAL_ROOT=$(cd "$RW_LOCAL_ROOT" && pwd -P)
  RW_REMOTE_ROOT="/tmp/rw-bd-${RANDOM}${RANDOM}"
  RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
  RW_OWN_MAP=1
else
  first="${RW_PATH_MAP%%;*}"
  RW_LOCAL_ROOT="${first%%|*}"
  RW_REMOTE_ROOT="${first#*|}"
  RW_OWN_MAP=0
fi
export RW_PATH_MAP RW_LOCAL_ROOT RW_REMOTE_ROOT
RW_STATE=$(mktemp -d /tmp/rw-bd-state.XXXXXX)
export RW_STATE
mkdir -p "$RW_EVIDENCE" "$RW_RAW"
proof_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT")" || {
  printf 'run: could not prepare remote scratch\n' >&2
  exit 1
}

ids=()
if [[ ${#PROOF_REST[@]} -eq 0 ]]; then
  ids=(2 3 5 6 4 7 8 9)
else
  for item in "${PROOF_REST[@]}"; do
    ids+=("${item#B}")
    ids[${#ids[@]}-1]="${ids[${#ids[@]}-1]#b}"
  done
fi

runner_cleanup() {
  local rc=$?
  if [[ "${RW_OWN_MAP:-0}" == 1 ]]; then
    rm -rf "$RW_LOCAL_ROOT"
    proof_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT")" >/dev/null 2>&1 || true
  fi
  rm -rf "$RW_STATE"
  proof_ssh_exit
  exit "$rc"
}
trap runner_cleanup EXIT

label=$(proof_label)
fail_n=0
pass_n=0
summary="${RW_RAW}/summary-${label}.txt"
: >"$summary"
printf 'label: %s\nplane: ssh-sync\nwhen: %s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$summary"

for id in "${ids[@]}"; do
  script="${HERE}/b${id}.sh"
  if [[ ! -f "$script" ]]; then
    printf 'MISSING b%s\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
    continue
  fi
  if "$script" --target "$RW_SSH_TARGET" --map "$RW_PATH_MAP" --evidence "$RW_EVIDENCE" --label "$label"; then
    printf 'b%s PASS\n' "$id" | tee -a "$summary"
    pass_n=$((pass_n + 1))
  else
    printf 'b%s FAIL\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
  fi
done

printf 'summary pass=%s fail=%s\n' "$pass_n" "$fail_n" | tee -a "$summary"
mkdir -p "$RW_EVIDENCE"
# shellcheck disable=SC2034
NOTES=$(mktemp)
proof_redact_file "$summary" "${RW_EVIDENCE}/${label}-summary.log"
rm -f "$NOTES"
if [[ "$fail_n" -gt 0 ]]; then
  exit 1
fi
exit 0
