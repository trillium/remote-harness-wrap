#!/bin/bash
# D5. The no-VM route runs the forwarder while no guest is running.
# Group C harness sessions are not part of this proof.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
RW_LABEL="${RW_LABEL:-provider-mac}"
intercept_begin "$@"
running=$(limactl list | awk 'NR>1 && $2=="Running" {c++} END {print c+0}')
note "lima_running=$running"
if [[ "$running" == 0 ]]; then
  pass "no guest is running"
else
  fail "a guest is running"
fi

if [[ -z "${RW_SSH_TARGET:-}" ]]; then
  fail "no ssh target for the no-VM forwarder"
  note "assertion_status: unproven"
  proof_finish d5
fi

intercept_build
direct=$(proof_ssh /bin/hostname || true)
direct=$(printf '%s' "$direct" | tr -d '\r\n')
local_name=$(hostname)
forwarded=$(intercept_probe /bin/hostname || true)
forwarded=$(printf '%s' "$forwarded" | tr -d '\r\n')
if [[ -n "$forwarded" && "$forwarded" == "$direct" && "$forwarded" != "$local_name" ]]; then
  pass "forwarder ran on this machine with no guest"
else
  fail "no-VM forwarder did not reach the remote"
fi
note "assertion_status: partial"
note "reason: the no-VM forwarder ran; group C harness sessions were not part of this proof"
proof_finish d5
