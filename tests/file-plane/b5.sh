#!/bin/bash
# B5. Listing after a remote create, rename, and delete matches the remote.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

compare() {
  local title="$1" local_names remote_names
  if ! plane_pull; then
    fail "$title pull"
    return
  fi
  local_names=$(plane_names "$RW_LOCAL_ROOT")
  remote_names=$(plane_remote_names)
  if [[ "$local_names" == "$remote_names" ]]; then
    pass "$title"
  else
    fail "$title"
  fi
}

proof_ssh "printf a > $(printf '%q' "$RW_REMOTE_ROOT/a.txt"); printf b > $(printf '%q' "$RW_REMOTE_ROOT/b.txt")"
compare "create"

proof_ssh "mv $(printf '%q' "$RW_REMOTE_ROOT/a.txt") $(printf '%q' "$RW_REMOTE_ROOT/c.txt")"
compare "rename"

proof_ssh "rm -f $(printf '%q' "$RW_REMOTE_ROOT/b.txt")"
compare "delete"

if plane_names "$RW_LOCAL_ROOT" | grep -qx './c.txt'; then
  pass "renamed name is present"
else
  fail "renamed name is absent"
fi
if plane_names "$RW_LOCAL_ROOT" | grep -qx './a.txt'; then
  fail "old name is still present"
else
  pass "old name is gone"
fi
if plane_names "$RW_LOCAL_ROOT" | grep -qx './b.txt'; then
  fail "deleted name is still present"
else
  pass "deleted name is gone"
fi

proof_finish b5
