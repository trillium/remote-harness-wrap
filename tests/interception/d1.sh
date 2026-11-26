#!/bin/bash
# D1. A preloaded forwarder runs a command on the remote.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
intercept_begin "$@"
intercept_build
note "route: dyld"

direct=$(proof_ssh /bin/hostname || true)
direct=$(printf '%s' "$direct" | tr -d '\r\n')
local_name=$(hostname)
forwarded=$(intercept_probe /bin/hostname || true)
forwarded=$(printf '%s' "$forwarded" | tr -d '\r\n')
log=${RW_FWD_LOG:-$RW_RAW/forward.log}

if [[ -n "$forwarded" && "$forwarded" == "$direct" && "$forwarded" != "$local_name" ]]; then
  pass "forwarded command matches the remote and not this machine"
else
  fail "forwarded command did not match the remote"
fi
if grep -q 'decision=forward-spawn path=/bin/hostname' "$log"; then
  pass "forwarder log records the spawn"
else
  fail "forwarder log missing the spawn"
fi
proof_finish d1
