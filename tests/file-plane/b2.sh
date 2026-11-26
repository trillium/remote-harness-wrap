#!/bin/bash
# B2. A provider write, then a push, is what the remote reads next.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

printf 'from-provider\n' >"$RW_LOCAL_ROOT/from-provider.txt"
if plane_push; then
  pass "push exited 0"
else
  fail "push failed"
fi
got=$(proof_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/from-provider.txt")" || true)
got=${got//$'\r'/}
got=${got%$'\n'}
if [[ "$got" == "from-provider" ]]; then
  pass "remote read matches the provider write"
else
  fail "remote read mismatch"
fi

printf 'edited\n' >"$RW_LOCAL_ROOT/from-provider.txt"
if plane_push; then
  pass "edit push exited 0"
else
  fail "edit push failed"
fi
got=$(proof_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/from-provider.txt")" || true)
got=${got//$'\r'/}
got=${got%$'\n'}
if [[ "$got" == "edited" ]]; then
  pass "remote read matches the provider edit"
else
  fail "remote edit mismatch"
fi

proof_finish b2
