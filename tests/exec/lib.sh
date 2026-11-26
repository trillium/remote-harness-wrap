#!/bin/bash
# Shared helpers for the exec-plane proofs. Sourced by tests/exec/*.sh.
# A test fails by recording FAIL lines and exiting non-zero.

exec_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

exec_label() {
  if [[ -n "${RW_LABEL:-}" ]]; then
    printf '%s' "$RW_LABEL"
    return 0
  fi
  case "${RW_SSH_TARGET:-localhost}" in
    localhost | 127.0.0.1) printf 'local' ;;
    *) printf 'remote' ;;
  esac
}

exec_ssh() {
  ssh \
    -o ControlMaster=auto \
    -o "ControlPersist=${RW_CONTROL_PERSIST:-30m}" \
    -o "ControlPath=${RW_CONTROL_PATH:-/tmp/rw-exec-%C}" \
    -o BatchMode=yes \
    -o "ConnectTimeout=${RW_CONNECT_TIMEOUT:-8}" \
    -o LogLevel=ERROR \
    -T "$RW_SSH_TARGET" "$@"
}

exec_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        RW_SSH_TARGET="$2"
        shift 2
        ;;
      --map)
        RW_PATH_MAP="$2"
        shift 2
        ;;
      --evidence)
        RW_EVIDENCE="$2"
        shift 2
        ;;
      --label)
        RW_LABEL="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  EXEC_REST=("$@")
}

exec_reject_secrets() {
  local file="$1" token
  [[ -f "$file" ]] || return 0
  token="${RW_TOKEN_FILE:-}"
  if [[ -n "$token" && -f "$token" ]] && grep -F -q -f "$token" "$file"; then
    rm -f "$file"
    printf 'refusing evidence: sensitive material\n' >&2
    exit 1
  fi
  if grep -E -q 'sk-ant-|sk-or-v1-' "$file"; then
    rm -f "$file"
    printf 'refusing evidence: sensitive material\n' >&2
    exit 1
  fi
}

exec_redact_file() {
  local src="$1" dest="$2"
  RW_REDACT_HOME="$HOME" \
  RW_REDACT_USER="$(id -un)" \
  RW_REDACT_HOST="$(hostname)" \
  RW_REDACT_TARGET="${RW_SSH_TARGET:-}" \
  RW_REDACT_LABEL="$(exec_label)" \
  perl -pe '
    BEGIN {
      $home = $ENV{RW_REDACT_HOME} // "";
      $user = $ENV{RW_REDACT_USER} // "";
      $host = $ENV{RW_REDACT_HOST} // "";
      $target = $ENV{RW_REDACT_TARGET} // "";
      $label = $ENV{RW_REDACT_LABEL} // "remote";
    }
    s/\Q$home\E/\/Users\/user/g if length($home);
    if (length($target) && $target ne "localhost" && $target ne "127.0.0.1") {
      my $q = quotemeta($target);
      s/$q/$label/g;
    }
    s/\Q$host\E/provider-mac/g if length($host);
    if (length($user) && $user ne "user") {
      my $q = quotemeta($user);
      s/$q/user/g;
    }
    s/\b\d{1,3}(?:\.\d{1,3}){3}\b/redacted-ip/g;
  ' "$src" >"$dest"
}

exec_wrapper() {
  local cwd="$1" script="$2"
  (
    cd "$cwd" || exit 97
    export RW_SSH_TARGET RW_PATH_MAP
    export RW_TRANSPORT="${RW_TRANSPORT:-broker}"
    export RW_ALLOW_VARS="${RW_ALLOW_VARS:-}"
    export RW_CONNECT_TIMEOUT="${RW_CONNECT_TIMEOUT:-8}"
    export RW_BROKER_ROOT="${RW_BROKER_ROOT:-/tmp/rw-exec-broker}"
    export RW_CONTROL_PATH="${RW_CONTROL_PATH:-/tmp/rw-exec-%C}"
    export RW_CONTROL_PERSIST="${RW_CONTROL_PERSIST:-30m}"
    if [[ -n "${RW_RUN_LOG:-}" ]]; then
      export RW_LOG="$RW_RUN_LOG"
    else
      unset RW_LOG
    fi
    "$RW_WRAP" -c -l "$script"
  )
}

exec_stop_broker() {
  exec_ssh /bin/bash --noprofile --norc -s <<'EOF' >/dev/null 2>&1 || true
root=/tmp/rw-exec-broker
if [[ -f $root/broker.pid ]]; then
  kill "$(cat "$root/broker.pid")" 2>/dev/null || true
fi
shopt -s nullglob
for p in "$root"/jobs/*/pid; do
  k=$(tr -cd '0-9' <"$p")
  [[ -n "$k" ]] || continue
  kill -TERM -"$k" 2>/dev/null || kill -TERM "$k" 2>/dev/null || true
  kill -KILL -"$k" 2>/dev/null || true
done
rm -rf "$root"
EOF
}

exec_master_exit() {
  ssh \
    -o ControlPath="${RW_CONTROL_PATH:-/tmp/rw-exec-%C}" \
    -o LogLevel=ERROR \
    -O exit "$RW_SSH_TARGET" >/dev/null 2>&1 || true
}

exec_wipe_scratch() {
  if [[ -n "${RW_LOCAL_ROOT:-}" ]]; then
    rm -rf "$RW_LOCAL_ROOT"
  fi
  if [[ -n "${RW_REMOTE_ROOT:-}" && -n "${RW_SSH_TARGET:-}" ]]; then
    exec_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT")" >/dev/null 2>&1 || true
  fi
  exec_stop_broker
  exec_master_exit
}

exec_cleanup() {
  local rc=$?
  if [[ -n "${RW_EXTRA_CLEAN:-}" ]]; then
    # shellcheck disable=SC2086
    eval "$RW_EXTRA_CLEAN" || true
  fi
  if [[ "${RW_KEEP_SESSION:-0}" != 1 && "${RW_OWN_MAP:-0}" == 1 ]]; then
    exec_wipe_scratch
  fi
  [[ -n "${NOTES:-}" ]] && rm -f "$NOTES"
  exit "$rc"
}

exec_begin() {
  exec_parse_args "$@"
  RW_SSH_TARGET="${RW_SSH_TARGET:-localhost}"
  RW_WRAP="${RW_WRAP:-$(exec_root)/src/rw-bash}"
  RW_EVIDENCE="${RW_EVIDENCE:-$(exec_root)/evidence/exec}"
  RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-exec-proof-raw}"
  RW_CONTROL_PATH="${RW_CONTROL_PATH:-/tmp/rw-exec-%C}"
  RW_CONTROL_PERSIST="${RW_CONTROL_PERSIST:-30m}"
  mkdir -p "$RW_RAW" "$RW_EVIDENCE"
  NOTES=$(mktemp "${TMPDIR:-/tmp}/rw-notes.XXXXXX")
  PASSES=0
  FAILS=0
  if [[ -z "${RW_PATH_MAP:-}" ]]; then
    RW_LOCAL_ROOT=$(mktemp -d /tmp/rw-exec-local.XXXXXX)
    if [[ "$RW_SSH_TARGET" == localhost || "$RW_SSH_TARGET" == 127.0.0.1 ]]; then
      RW_REMOTE_ROOT=$(mktemp -d /tmp/rw-exec-remote.XXXXXX)
    else
      RW_REMOTE_ROOT="/tmp/rw-exec-remote.${RANDOM}${RANDOM}"
    fi
    RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
    RW_OWN_MAP=1
  else
    local first="${RW_PATH_MAP%%;*}"
    RW_LOCAL_ROOT="${first%%|*}"
    RW_REMOTE_ROOT="${first#*|}"
    RW_OWN_MAP=0
  fi
  mkdir -p "$RW_LOCAL_ROOT/proj"
  exec_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT/proj")" \
    || {
      note "could not prepare the remote scratch directory"
      FAILS=$((FAILS + 1))
    }
  export RW_SSH_TARGET RW_PATH_MAP RW_LOCAL_ROOT RW_REMOTE_ROOT RW_WRAP RW_EVIDENCE RW_RAW
  export RW_CONTROL_PATH RW_CONTROL_PERSIST
  trap exec_cleanup EXIT
}

note() {
  printf '%s\n' "$*" | tee -a "$NOTES"
}

pass() {
  PASSES=$((PASSES + 1))
  note "PASS: $*"
}

fail() {
  FAILS=$((FAILS + 1))
  note "FAIL: $*"
}

exec_finish() {
  local id="$1" label dest raw
  label=$(exec_label)
  dest="${RW_EVIDENCE}/${label}-${id}.log"
  raw="${RW_RAW}/${label}-${id}.log"
  mkdir -p "$RW_EVIDENCE" "$(dirname "$raw")"
  {
    printf 'id: %s\n' "$id"
    printf 'label: %s\n' "$label"
    printf 'when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'passes: %s\n' "$PASSES"
    printf 'fails: %s\n' "$FAILS"
    cat "$NOTES"
  } >"$raw"
  exec_reject_secrets "$raw"
  exec_redact_file "$raw" "$dest"
  exec_reject_secrets "$dest"
  if [[ "$FAILS" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
