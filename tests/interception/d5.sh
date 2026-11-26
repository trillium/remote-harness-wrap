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

# Group C sessions, still with no guest. A harness that cannot authenticate
# is not a possible session; the coverage log records that blocker.
cover_root=$(cd "$HERE/../.." && pwd)
for id in c1 c2 c3 c4 c5 c6 c7 c8; do
  script="$HERE/../coverage/${id}.sh"
  note "coverage=${id} guest=no"
  if [[ "$id" == c1 || "$id" == c4 ]]; then
    if [[ -z "${RW_TOKEN_FILE:-}" || ! -s "${RW_TOKEN_FILE:-}" ]]; then
      note "coverage=${id} not-possible reason=token-file-missing"
      continue
    fi
  fi
  if [[ "${RW_D5_REUSE:-}" == 1 && -f "${cover_root}/evidence/coverage/${id}.log" ]]; then
    rc=0
    note "coverage=${id} source=existing-log"
  else
    env -u RW_EVIDENCE -u RW_PATH_MAP -u RW_LOCAL_ROOT -u RW_REMOTE_ROOT -u RW_STATE -u RW_OWN_MAP \
      "$script" --target "$RW_SSH_TARGET" --label remote
    rc=$?
  fi
  log="${cover_root}/evidence/coverage/${id}.log"
  if [[ "$rc" -eq 0 ]]; then
    pass "C session ${id} ran with no guest"
  elif [[ -f "$log" ]] && grep -E -q 'claude_exit:|opencode_exit:|codex_exec_exit:|grok_exit:' "$log"; then
    pass "C session ${id} ran with no guest"
    note "coverage=${id} finished with assertion fails"
  elif [[ -f "$log" ]] && grep -E -q 'account-refused|auth: 401|auth: limit|usage limit|unsupported' "$log"; then
    note "coverage=${id} not-possible"
  else
    fail "C session ${id} did not complete on the no-VM route"
  fi
done
running=$(limactl list | awk 'NR>1 && $2=="Running" {c++} END {print c+0}')
note "lima_running_after=$running"
if [[ "$running" == 0 ]]; then
  pass "no guest is running after the C sessions"
else
  fail "a guest is running after the C sessions"
fi
if [[ "$FAILS" -eq 0 ]]; then
  note "assertion_status: proven"
else
  note "assertion_status: partial"
fi
proof_finish d5
