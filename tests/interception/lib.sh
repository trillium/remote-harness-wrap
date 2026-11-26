#!/bin/bash
# Interception proof helpers. Sourced by tests/interception/*.sh.
HERE_INT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/proof.sh
. "$HERE_INT/../lib/proof.sh"

intercept_cleanup() {
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

intercept_begin() {
  export RW_EVIDENCE_PLANE=interception
  proof_prepare "$@"
  RW_SSH_TARGET="${RW_SSH_TARGET:-}"
  if [[ -n "$RW_SSH_TARGET" && -z "${RW_REMOTE_NAME:-}" ]]; then
    RW_REMOTE_NAME=$(proof_ssh hostname 2>/dev/null | tr -d '\r\n' || true)
    export RW_REMOTE_NAME
  fi
  if [[ -z "${RW_PATH_MAP:-}" ]]; then
    RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-bd-local.XXXXXX)
    RW_REMOTE_ROOT="/tmp/rw-bd-${RANDOM}${RANDOM}"
    RW_OWN_MAP=1
  else
    local first="${RW_PATH_MAP%%;*}"
    RW_LOCAL_ROOT="${first%%|*}"
    RW_REMOTE_ROOT="${first#*|}"
    RW_OWN_MAP=0
  fi
  RW_LOCAL_ROOT=$(cd "$RW_LOCAL_ROOT" && pwd -P)
  RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
  RW_STATE="${RW_STATE:-$(mktemp -d /tmp/rw-bd-state.XXXXXX)}"
  mkdir -p "$RW_LOCAL_ROOT" "$RW_RAW/build"
  if [[ -n "$RW_SSH_TARGET" ]]; then
    proof_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT")" || {
      note "could not prepare the remote scratch directory"
      FAILS=$((FAILS + 1))
    }
  fi
  export RW_SSH_TARGET RW_PATH_MAP RW_LOCAL_ROOT RW_REMOTE_ROOT RW_STATE RW_OWN_MAP
  trap intercept_cleanup EXIT
}

intercept_build() {
  local dylib="$RW_RAW/build/fwd.dylib" probe="$RW_RAW/build/spawn-probe"
  if [[ ! -f "$dylib" || "$RW_ROOT/src/forwarder-mac.c" -nt "$dylib" ]]; then
    clang -dynamiclib -fPIC -O2 -Wall -Wextra -Wno-deprecated-declarations \
      -o "$dylib" "$RW_ROOT/src/forwarder-mac.c"
  fi
  if [[ ! -f "$probe" || "$HERE_INT/spawn-probe.c" -nt "$probe" ]]; then
    clang -O2 -Wall -Wextra -o "$probe" "$HERE_INT/spawn-probe.c"
  fi
  RW_DYLIB="$dylib"
  RW_PROBE="$probe"
  export RW_DYLIB RW_PROBE
}

intercept_probe() {
  DYLD_INSERT_LIBRARIES="$RW_DYLIB" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_LOG="${RW_FWD_LOG:-$RW_RAW/forward.log}" \
    RW_ENV_MODE=reduced \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_GUEST_ROOT="$RW_LOCAL_ROOT" \
    RW_REMOTE_ROOT="$RW_REMOTE_ROOT" \
    "$RW_PROBE" "$@"
}
