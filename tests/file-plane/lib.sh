#!/bin/bash
# File-plane proof helpers. Sourced by tests/file-plane/*.sh.
HERE_PLANE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/proof.sh
. "$HERE_PLANE/../lib/proof.sh"

plane_cleanup() {
  local rc=$?
  if [[ "${RW_KEEP_SESSION:-0}" != 1 && "${RW_OWN_MAP:-0}" == 1 ]]; then
    if [[ -n "${RW_LOCAL_ROOT:-}" ]]; then
      rm -rf "$RW_LOCAL_ROOT"
    fi
    if [[ -n "${RW_REMOTE_ROOT:-}" && -n "${RW_SSH_TARGET:-}" ]]; then
      proof_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT")" >/dev/null 2>&1 || true
    fi
    if [[ -n "${RW_STATE:-}" ]]; then
      rm -rf "$RW_STATE"
    fi
    proof_ssh_exit
  fi
  [[ -n "${NOTES:-}" ]] && rm -f "$NOTES"
  exit "$rc"
}

plane_begin() {
  export RW_EVIDENCE_PLANE=file-plane
  proof_prepare "$@"
  RW_SSH_TARGET="${RW_SSH_TARGET:-}"
  [[ -n "$RW_SSH_TARGET" ]] || {
    note "missing ssh target"
    FAILS=$((FAILS + 1))
    return 0
  }
  if [[ -z "${RW_REMOTE_NAME:-}" ]]; then
    RW_REMOTE_NAME=$(proof_ssh hostname 2>/dev/null | tr -d '\r\n' || true)
    export RW_REMOTE_NAME
  fi
  if [[ -z "${RW_PATH_MAP:-}" ]]; then
    RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-bd-local.XXXXXX)
    RW_REMOTE_ROOT="/tmp/rw-bd-${RANDOM}${RANDOM}"
    RW_OWN_MAP=1
    RW_STATE=$(mktemp -d /tmp/rw-bd-state.XXXXXX)
  else
    local first="${RW_PATH_MAP%%;*}"
    RW_LOCAL_ROOT="${first%%|*}"
    RW_REMOTE_ROOT="${first#*|}"
    RW_OWN_MAP=0
    RW_STATE="${RW_STATE:-$(mktemp -d /tmp/rw-bd-state.XXXXXX)}"
  fi
  RW_LOCAL_ROOT=$(cd "$RW_LOCAL_ROOT" && pwd -P)
  RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
  mkdir -p "$RW_LOCAL_ROOT"
  proof_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT")" || {
    note "could not prepare the remote scratch directory"
    FAILS=$((FAILS + 1))
  }
  export RW_SSH_TARGET RW_PATH_MAP RW_LOCAL_ROOT RW_REMOTE_ROOT RW_STATE RW_OWN_MAP
  trap plane_cleanup EXIT
}

plane_push() {
  RW_STATE="$RW_STATE" "$RW_BIN" sync \
    --remote "$RW_SSH_TARGET" \
    --project "$RW_REMOTE_ROOT" \
    --local "$RW_LOCAL_ROOT" \
    push
}

plane_pull() {
  RW_STATE="$RW_STATE" "$RW_BIN" sync \
    --remote "$RW_SSH_TARGET" \
    --project "$RW_REMOTE_ROOT" \
    --local "$RW_LOCAL_ROOT" \
    pull
}

plane_names() {
  local dir="$1"
  (cd "$dir" && find . -print | LC_ALL=C sort)
}

plane_remote_names() {
  proof_ssh "cd $(printf '%q' "$RW_REMOTE_ROOT") && find . -print | LC_ALL=C sort"
}

plane_sha() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

plane_mode() {
  python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

plane_remote_py() {
  local script="$1"
  proof_ssh "python3 -c $(printf '%q' "$script")"
}
