#!/bin/bash
# F5. Follow the fenced setup commands in README.md.
# The peer aliases stay in the environment. The evidence names the label only.
#
#   RW_SSH_LINUX=<alias> tests/whole/f5.sh linux
#   RW_SSH_MAC=<alias> tests/whole/f5.sh mac
#   tests/whole/f5.sh local
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/proof.sh
. "$HERE/../lib/proof.sh"
export RW_EVIDENCE_PLANE=whole
ROOT=$(cd "$HERE/../.." && pwd)
which_peer=${1:-}
proof_prepare --label "f5-${which_peer:-unset}"

case "$which_peer" in
  linux)
    [[ -n "${RW_SSH_LINUX:-}" ]] || {
      fail "linux peer is not set"
      proof_finish f5
    }
    if ! grep -F -q 'RW_LABEL=remote-linux tests/file-plane/run.sh' "$ROOT/README.md"; then
      fail "README is missing the remote-linux file-plane command"
      proof_finish f5
    fi
    note "readme_command=RW_SSH_TARGET=<ssh-host> RW_LABEL=remote-linux tests/file-plane/run.sh"
    ( cd "$ROOT" && env -u RW_EVIDENCE -u RW_EVIDENCE_PLANE RW_SSH_TARGET="$RW_SSH_LINUX" RW_LABEL=remote-linux tests/file-plane/run.sh )
    rc=$?
    note "ran_exit=${rc}"
    if [[ "$rc" -eq 0 ]]; then
      pass "remote-linux file-plane command passed"
    else
      fail "remote-linux file-plane command failed"
    fi
    ;;
  mac)
    [[ -n "${RW_SSH_MAC:-}" ]] || {
      note "mac peer unavailable"
      note "assertion_status: partial"
      proof_finish f5
    }
    if ! grep -F -q 'RW_LABEL=remote-mac tests/file-plane/run.sh' "$ROOT/README.md"; then
      fail "README is missing the remote-mac file-plane command"
      proof_finish f5
    fi
    note "readme_command=RW_SSH_TARGET=<ssh-host> RW_LABEL=remote-mac tests/file-plane/run.sh"
    ( cd "$ROOT" && env -u RW_EVIDENCE -u RW_EVIDENCE_PLANE RW_SSH_TARGET="$RW_SSH_MAC" RW_LABEL=remote-mac tests/file-plane/run.sh )
    rc=$?
    note "ran_exit=${rc}"
    if [[ "$rc" -eq 0 ]]; then
      pass "remote-mac file-plane command passed"
    else
      fail "remote-mac file-plane command failed"
    fi
    ;;
  local)
    if ! grep -F -q 'RW_SSH_TARGET=localhost tests/exec/run.sh' "$ROOT/README.md"; then
      fail "README is missing the localhost exec command"
      proof_finish f5
    fi
    if ! grep -F -q 'tests/file-plane/b1.sh' "$ROOT/README.md"; then
      fail "README is missing the provider mount command"
      proof_finish f5
    fi
    note "readme_command=RW_SSH_TARGET=localhost tests/exec/run.sh"
    ( cd "$ROOT" && env -u RW_EVIDENCE -u RW_EVIDENCE_PLANE RW_SSH_TARGET=localhost tests/exec/run.sh )
    rc=$?
    note "exec_exit=${rc}"
    if [[ "$rc" -eq 0 ]]; then
      pass "localhost exec command passed"
    else
      fail "localhost exec command failed"
    fi
    note "readme_command=tests/file-plane/b1.sh"
    ( cd "$ROOT" && env -u RW_EVIDENCE -u RW_EVIDENCE_PLANE tests/file-plane/b1.sh )
    rc=$?
    note "b1_exit=${rc}"
    if [[ "$rc" -eq 0 ]]; then
      pass "provider mount command passed"
    else
      fail "provider mount command failed"
    fi
    ;;
  *)
    fail "usage: f5.sh linux|mac|local"
    ;;
esac
proof_finish f5
