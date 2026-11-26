#!/bin/bash
# B3. A file created on the remote is listed and read on the provider.
# 50 creates. A miss is a name or body that is not there after pull.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

miss_list=0
miss_read=0
first_miss=""
start=$(date +%s)
i=1
while [[ $i -le 50 ]]; do
  token="b3-$i"
  name="f-$i.txt"
  if ! proof_ssh "printf '%s\n' $(printf '%q' "$token") > $(printf '%q' "$RW_REMOTE_ROOT/$name")"; then
    miss_list=$((miss_list + 1))
    miss_read=$((miss_read + 1))
    [[ -n "$first_miss" ]] || first_miss="create-$i"
    i=$((i + 1))
    continue
  fi
  if ! plane_pull; then
    miss_list=$((miss_list + 1))
    miss_read=$((miss_read + 1))
    [[ -n "$first_miss" ]] || first_miss="pull-$i"
    i=$((i + 1))
    continue
  fi
  if ! python3 -c 'import os,sys; raise SystemExit(0 if sys.argv[2] in os.listdir(sys.argv[1]) else 1)' "$RW_LOCAL_ROOT" "$name"; then
    miss_list=$((miss_list + 1))
    [[ -n "$first_miss" ]] || first_miss="list-$i"
  fi
  body=""
  if [[ -f "$RW_LOCAL_ROOT/$name" ]]; then
    body=$(cat "$RW_LOCAL_ROOT/$name" || true)
    body=${body//$'\r'/}
    body=${body%$'\n'}
  fi
  if [[ "$body" != "$token" ]]; then
    miss_read=$((miss_read + 1))
    [[ -n "$first_miss" ]] || first_miss="read-$i"
  fi
  i=$((i + 1))
done
end=$(date +%s)
note "n=50 seconds=$((end - start)) miss_list=$miss_list miss_read=$miss_read first_miss=${first_miss:-none}"
if [[ $miss_list -eq 0 && $miss_read -eq 0 ]]; then
  pass "50 creates were listed and read"
else
  fail "misses list=$miss_list read=$miss_read"
fi
proof_finish b3
