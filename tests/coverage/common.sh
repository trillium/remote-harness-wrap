#!/bin/bash
# Shared setup for exec-plane coverage proofs. Sourced by tests/coverage/*.sh.
# Evidence committed under evidence/coverage/ is redacted. Raw logs stay outside
# the worktree.

coverage_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

# shellcheck source=../exec/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../exec" && pwd)/lib.sh"

coverage_begin() {
  export RW_BROKER_ROOT="${RW_BROKER_ROOT:-/tmp/rw-coverage-broker}"
  export RW_CONTROL_PATH="${RW_CONTROL_PATH:-/tmp/rw-cov-%C}"
  export RW_CONTROL_PERSIST="${RW_CONTROL_PERSIST:-30m}"
  export RW_TRANSPORT="${RW_TRANSPORT:-broker}"
  export RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-coverage-raw}"
  mkdir -p "$RW_RAW"
  exec_begin "$@"
  case "${RW_EVIDENCE:-}" in
    "" | */evidence/exec) RW_EVIDENCE="$(coverage_root)/evidence/coverage" ;;
  esac
  mkdir -p "$RW_EVIDENCE"
  export RW_EVIDENCE
  RW_REMOTE_HOSTNAME=$(exec_ssh hostname 2>/dev/null | tr -d '[:space:]' || true)
  RW_PROVIDER_HOSTNAME=$(hostname | tr -d '[:space:]')
  export RW_REMOTE_HOSTNAME RW_PROVIDER_HOSTNAME
}

coverage_timeout() {
  local secs="$1"
  shift
  "$@" &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt "$secs" ]]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
}

coverage_finish() {
  local id="$1" raw dest
  raw="${RW_RAW}/${id}.log"
  dest="${RW_EVIDENCE}/${id}.log"
  mkdir -p "$RW_EVIDENCE" "$(dirname "$raw")"
  {
    printf 'id: %s\n' "$id"
    printf 'when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'passes: %s\n' "$PASSES"
    printf 'fails: %s\n' "$FAILS"
    cat "$NOTES"
  } >"$raw"
  exec_reject_secrets "$raw"
  exec_redact_file "$raw" "$dest"
  if [[ -n "${RW_REMOTE_HOSTNAME:-}" ]]; then
    RW_REMOTE_HOSTNAME="$RW_REMOTE_HOSTNAME" \
      RW_SSH_TARGET="${RW_SSH_TARGET:-}" \
      RW_REDACT_LABEL="$(exec_label)" \
      perl -i -pe '
      my $h = $ENV{RW_REMOTE_HOSTNAME} // "";
      my $target = $ENV{RW_SSH_TARGET} // "";
      my $label = $ENV{RW_REDACT_LABEL} // "remote";
      my @forms = ($h);
      if (length($target) && length($h)) {
        my $q = quotemeta($target);
        (my $swapped = $h) =~ s/$q/$label/g;
        push @forms, $swapped;
      }
      for my $form (@forms) {
        next unless length($form);
        my $q = quotemeta($form);
        s/$q/remote-host/g;
      }
    ' "$dest"
  fi
  exec_reject_secrets "$dest"
  if [[ "$FAILS" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}
