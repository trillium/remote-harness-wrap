#!/bin/bash
# Run the exec-plane coverage proofs against one ssh target.
#
#   tests/coverage/run.sh --target lnx
#   tests/coverage/run.sh --target lnx a10 a11
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"

exec_parse_args "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-localhost}"
export RW_SSH_TARGET
ids=()
if [[ ${#EXEC_REST[@]} -eq 0 ]]; then
  ids=(a10 a11 c1 c4 c5 c7 c8)
else
  ids=("${EXEC_REST[@]}")
fi

fail_n=0
pass_n=0
for id in "${ids[@]}"; do
  script="${HERE}/${id}.sh"
  if [[ ! -f "$script" ]]; then
    printf 'MISSING %s\n' "$id"
    fail_n=$((fail_n + 1))
    continue
  fi
  if "$script" --target "$RW_SSH_TARGET" --label remote; then
    printf '%s PASS\n' "$id"
    pass_n=$((pass_n + 1))
  else
    printf '%s FAIL\n' "$id"
    fail_n=$((fail_n + 1))
  fi
done
printf 'summary pass=%s fail=%s\n' "$pass_n" "$fail_n"
if [[ "$fail_n" -gt 0 ]]; then
  exit 1
fi
exit 0
