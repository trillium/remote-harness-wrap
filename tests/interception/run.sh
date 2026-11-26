#!/bin/bash
# Run interception assertions.
#
#   RW_SSH_TARGET=<host> RW_LABEL=remote-linux tests/interception/run.sh D1 D2
#   RW_LABEL=provider-mac tests/interception/run.sh D3 D4 D5
#
# Logs land in evidence/interception/.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

proof_parse_args "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-}"
export RW_SSH_TARGET
RW_KEEP_SESSION=1
export RW_KEEP_SESSION
RW_ROOT=$(proof_root)
RW_EVIDENCE="${RW_EVIDENCE:-$RW_ROOT/evidence/interception}"
RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-bd-raw}"
export RW_EVIDENCE RW_RAW
mkdir -p "$RW_EVIDENCE" "$RW_RAW"

ids=()
if [[ ${#PROOF_REST[@]} -eq 0 ]]; then
  if [[ -n "$RW_SSH_TARGET" ]]; then
    ids=(1 2)
  else
    ids=(3 4 5)
  fi
else
  for item in "${PROOF_REST[@]}"; do
    ids+=("${item#D}")
    ids[${#ids[@]}-1]="${ids[${#ids[@]}-1]#d}"
  done
fi

if [[ -n "$RW_SSH_TARGET" && -z "${RW_PATH_MAP:-}" ]]; then
  RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-bd-local.XXXXXX)
  RW_LOCAL_ROOT=$(cd "$RW_LOCAL_ROOT" && pwd -P)
  RW_REMOTE_ROOT="/tmp/rw-bd-${RANDOM}${RANDOM}"
  RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
  RW_OWN_MAP=1
  proof_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT")" || {
    printf 'run: could not prepare remote scratch\n' >&2
    exit 1
  }
else
  RW_OWN_MAP=0
fi
export RW_PATH_MAP
RW_STATE=$(mktemp -d /tmp/rw-bd-state.XXXXXX)
export RW_STATE

runner_cleanup() {
  local rc=$?
  if [[ "${RW_OWN_MAP:-0}" == 1 ]]; then
    rm -rf "$RW_LOCAL_ROOT"
    if [[ -n "${RW_SSH_TARGET:-}" ]]; then
      proof_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT")" >/dev/null 2>&1 || true
      proof_ssh_exit
    fi
  fi
  rm -rf "$RW_STATE"
  exit "$rc"
}
trap runner_cleanup EXIT

label=$(proof_label)
fail_n=0
pass_n=0
summary="${RW_RAW}/summary-${label}.txt"
: >"$summary"
printf 'label: %s\nwhen: %s\n' "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$summary"

for id in "${ids[@]}"; do
  script="${HERE}/d${id}.sh"
  if [[ ! -f "$script" ]]; then
    printf 'MISSING d%s\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
    continue
  fi
  args=(--evidence "$RW_EVIDENCE" --label "$label")
  if [[ -n "$RW_SSH_TARGET" ]]; then
    args+=(--target "$RW_SSH_TARGET" --map "$RW_PATH_MAP")
  fi
  if "$script" "${args[@]}"; then
    printf 'd%s PASS\n' "$id" | tee -a "$summary"
    pass_n=$((pass_n + 1))
  else
    printf 'd%s FAIL\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
  fi
done

printf 'summary pass=%s fail=%s\n' "$pass_n" "$fail_n" | tee -a "$summary"
NOTES=$(mktemp)
proof_redact_file "$summary" "${RW_EVIDENCE}/${label}-summary.log"
rm -f "$NOTES"
if [[ "$fail_n" -gt 0 ]]; then
  exit 1
fi
exit 0
