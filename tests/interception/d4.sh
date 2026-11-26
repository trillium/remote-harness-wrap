#!/bin/bash
# D4. Measure guest memory only when a guest is running.
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
  note "assertion_status: unproven"
  note "reason: no virtual machine was required, so guest memory was not measured"
else
  fail "a guest is running and this proof did not measure it"
  note "assertion_status: unproven"
fi
proof_finish d4
