#!/bin/bash
# Run security assertions E1 through E5 against one target.
#
#   RW_SSH_TARGET=localhost RW_LABEL=local tests/security/run.sh
#   RW_LABEL=linux-peer tests/security/run.sh E1 E3
#
# The target is an ssh config Host supplied by the caller.
# This script does not name a host. Logs use RW_LABEL, not a hostname.
# With no map, scratch directories are created and removed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

exec_parse_args "$@"
sec_prepare
RW_SSH_TARGET="${RW_SSH_TARGET:-localhost}"
export RW_SSH_TARGET
RW_KEEP_SESSION=1
export RW_KEEP_SESSION

if [[ -z "${RW_PATH_MAP:-}" ]]; then
  RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-sec-local.XXXXXX)
  if [[ "$RW_SSH_TARGET" == localhost || "$RW_SSH_TARGET" == 127.0.0.1 ]]; then
    RW_REMOTE_ROOT=$(mktemp -d /tmp/rw-sec-remote.XXXXXX)
  else
    RW_REMOTE_ROOT="/tmp/rw-sec-remote.${RW_SEC_NONCE}"
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
mkdir -p "$RW_LOCAL_ROOT/proj" "$RW_EVIDENCE" "$RW_RAW"
exec_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT/proj")" || {
  printf 'run: could not prepare remote scratch\n' >&2
  exit 1
}

ids=()
if [[ ${#EXEC_REST[@]} -eq 0 ]]; then
  ids=(1 2 3 4 5)
else
  for item in "${EXEC_REST[@]}"; do
    ids+=("${item#E}")
    ids[${#ids[@]}-1]="${ids[${#ids[@]}-1]#e}"
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
  script="${HERE}/e${id}.sh"
  if [[ ! -f "$script" ]]; then
    printf 'MISSING e%s\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
    continue
  fi
  if "$script" --target "$RW_SSH_TARGET" --map "$RW_PATH_MAP" --evidence "$RW_EVIDENCE" --label "$label"; then
    printf 'e%s PASS\n' "$id" | tee -a "$summary"
    pass_n=$((pass_n + 1))
  else
    printf 'e%s FAIL\n' "$id" | tee -a "$summary"
    fail_n=$((fail_n + 1))
  fi
done

printf 'summary pass=%s fail=%s\n' "$pass_n" "$fail_n" | tee -a "$summary"
exec_redact_file "$summary" "${RW_EVIDENCE}/${label}-summary.log"

# Refuse to keep evidence that still contains a caller-supplied secret string
# or a raw address. RW_FORBIDDEN is a list of extra literals, one per line.
forbidden_hit=0
while IFS= read -r lit; do
  [[ -n "$lit" ]] || continue
  if grep -R -F -q -e "$lit" "$RW_EVIDENCE"; then
    printf 'run: evidence contains a forbidden literal\n' >&2
    forbidden_hit=1
  fi
done <<EOF
${RW_FORBIDDEN:-}
EOF
if grep -R -E -q -e '[0-9]{1,3}(\.[0-9]{1,3}){3}' -e 'ssh-ed25519 AAAA' -e 'SHA256:[A-Za-z0-9+/=]{10}' "$RW_EVIDENCE"; then
  printf 'run: evidence contains an address or a key\n' >&2
  forbidden_hit=1
fi
if [[ "$forbidden_hit" -ne 0 ]]; then
  exit 1
fi
if [[ "$fail_n" -gt 0 ]]; then
  exit 1
fi
exit 0
