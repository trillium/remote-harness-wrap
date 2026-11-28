#!/bin/bash
# Shared helpers for file-plane and interception proofs.
# A test fails by recording FAIL lines and exiting non-zero.

# shellcheck source=ssh-inband.sh
. "$(dirname "${BASH_SOURCE[0]}")/ssh-inband.sh"

proof_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

proof_label() {
  if [[ -n "${RW_LABEL:-}" ]]; then
    printf '%s' "$RW_LABEL"
    return 0
  fi
  case "${RW_SSH_TARGET:-localhost}" in
    localhost | 127.0.0.1 | "") printf 'local' ;;
    *) printf 'remote' ;;
  esac
}

proof_ssh() {
  rw_ssh_inband ssh \
    -o ControlMaster=auto \
    -o "ControlPersist=${RW_CONTROL_PERSIST:-5m}" \
    -o "ControlPath=${RW_CONTROL_PATH:-/tmp/rw-bd-%C}" \
    -o BatchMode=yes \
    -o "ConnectTimeout=${RW_CONNECT_TIMEOUT:-8}" \
    -o LogLevel=ERROR \
    -T \
    "$RW_SSH_TARGET" \
    -- "$@"
}

proof_ssh_exit() {
  ssh \
    -o "ControlPath=${RW_CONTROL_PATH:-/tmp/rw-bd-%C}" \
    -o LogLevel=ERROR \
    -O exit "${RW_SSH_TARGET:-}" >/dev/null 2>&1 || true
}

proof_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        RW_SSH_TARGET="$2"
        shift 2
        ;;
      --map)
        RW_PATH_MAP="$2"
        export RW_PATH_MAP
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
  # Used by the runners that source this file.
  # shellcheck disable=SC2034
  PROOF_REST=("$@")
}

proof_reject_secrets() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if grep -E -q 'sk-ant-|sk-or-v1-|ghp_|github_pat_|AKIA' "$file"; then
    rm -f "$file"
    printf 'refusing evidence: sensitive material\n' >&2
    exit 1
  fi
}

proof_redact_file() {
  local src="$1" dest="$2"
  RW_REDACT_HOME="$HOME" \
  RW_REDACT_USER="$(id -un)" \
  RW_REDACT_HOST="$(hostname)" \
  RW_REDACT_TARGET="${RW_SSH_TARGET:-}" \
  RW_REDACT_LABEL="$(proof_label)" \
  RW_REDACT_REMOTE="${RW_REMOTE_NAME:-}" \
    perl -pe '
      BEGIN {
        $home = $ENV{RW_REDACT_HOME} // "";
        $user = $ENV{RW_REDACT_USER} // "";
        $host = $ENV{RW_REDACT_HOST} // "";
        $target = $ENV{RW_REDACT_TARGET} // "";
        $label = $ENV{RW_REDACT_LABEL} // "remote";
        $remote = $ENV{RW_REDACT_REMOTE} // "";
      }
      s/\Q$home\E/\/Users\/user/g if length($home);
      if (length($target) && $target ne "localhost" && $target ne "127.0.0.1") {
        my $q = quotemeta($target);
        s/(?<![A-Za-z0-9._-])$q(?![A-Za-z0-9._-])/$label/g;
      }
      if (length($remote) && $remote ne "localhost") {
        my $q = quotemeta($remote);
        s/(?<![A-Za-z0-9._-])$q(?![A-Za-z0-9._-])/$label/g;
      }
      s/\Q$host\E/provider-mac/g if length($host);
      if (length($user) && $user ne "user") {
        my $q = quotemeta($user);
        s/(?<![A-Za-z0-9._-])$q(?![A-Za-z0-9._-])/user/g;
      }
      s/\b\d{1,3}(?:\.\d{1,3}){3}\b/redacted-ip/g;
    ' "$src" >"$dest"
}

proof_leak_check() {
  local file="$1" needle
  for needle in "${RW_SSH_TARGET:-}" "${RW_REMOTE_NAME:-}" "$(hostname)" "$(id -un)"; do
    [[ -n "$needle" ]] || continue
    [[ "$needle" == localhost || "$needle" == 127.0.0.1 || "$needle" == user ]] && continue
    if grep -F -q -w "$needle" "$file" || grep -F -q "$needle" "$file"; then
      rm -f "$file"
      printf 'refusing evidence: name remains\n' >&2
      exit 1
    fi
  done
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

proof_finish() {
  local id="$1" label dest raw
  label=$(proof_label)
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
  proof_reject_secrets "$raw"
  proof_redact_file "$raw" "$dest"
  proof_reject_secrets "$dest"
  proof_leak_check "$dest"
  if [[ "$FAILS" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

proof_prepare() {
  proof_parse_args "$@"
  RW_ROOT=$(proof_root)
  RW_EVIDENCE="${RW_EVIDENCE:-$RW_ROOT/evidence/${RW_EVIDENCE_PLANE:-proof}}"
  RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-bd-raw}"
  RW_CONTROL_PATH="${RW_CONTROL_PATH:-/tmp/rw-bd-%C}"
  RW_CONTROL_PERSIST="${RW_CONTROL_PERSIST:-5m}"
  RW_BIN="${RW_BIN:-$RW_ROOT/src/rw}"
  mkdir -p "$RW_RAW" "$RW_EVIDENCE"
  NOTES=$(mktemp "${TMPDIR:-/tmp}/rw-notes.XXXXXX")
  PASSES=0
  FAILS=0
  export RW_EVIDENCE RW_RAW RW_CONTROL_PATH RW_CONTROL_PERSIST RW_BIN RW_ROOT
}
