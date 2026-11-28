#!/bin/bash
# B7. The sync root is one directory, a second key is refused, and the
# remote command is not root.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

sib="/tmp/rw-bd-sib${RANDOM}${RANDOM}"
proof_ssh "mkdir -p $(printf '%q' "$sib") && printf secret > $(printf '%q' "$sib/secret.txt")" || fail "could not create sibling"
printf 'inside\n' >"$RW_LOCAL_ROOT/inside.txt"
plane_push || fail "push failed"
plane_pull || fail "pull failed"
if grep -R -q -F secret "$RW_LOCAL_ROOT"; then
  fail "sibling contents appeared in the mirror"
else
  pass "mirror does not contain the sibling directory"
fi
if "$RW_BIN" sync --remote "$RW_SSH_TARGET" --project /tmp --local "$RW_LOCAL_ROOT" pull >/dev/null 2>&1; then
  fail "sync accepted /tmp"
else
  pass "sync refuses a path outside one scratch directory"
fi
escaped="${RW_REMOTE_ROOT}/../$(basename "$sib")"
if "$RW_BIN" sync --remote "$RW_SSH_TARGET" --project "$escaped" --local "$RW_LOCAL_ROOT" pull >/dev/null 2>&1; then
  fail "sync accepted a path that climbs out"
else
  pass "sync refuses a path that climbs out"
fi

key=$(mktemp /tmp/rw-bd-key.XXXXXX)
rm -f "$key"
ssh-keygen -t ed25519 -N "" -q -f "$key" </dev/null
# ssh -G resolves the config destination. -F /dev/null then offers only the
# new key, so a key named in ssh_config cannot satisfy this check.
cfg=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null || true)
dest_user=$(printf '%s\n' "$cfg" | awk '$1=="user"{print $2; exit}')
dest_host=$(printf '%s\n' "$cfg" | awk '$1=="hostname"{print $2; exit}')
dest_port=$(printf '%s\n' "$cfg" | awk '$1=="port"{print $2; exit}')
unset cfg
verb=$(mktemp "${RW_RAW}/b7-auth.XXXXXX")
auth_rc=0
method=unknown
if [[ -n "$dest_user" && -n "$dest_host" && -n "$dest_port" ]]; then
  env -u SSH_AUTH_SOCK ssh \
    -F /dev/null \
    -o BatchMode=yes \
    -o ControlMaster=no \
    -o ControlPath=none \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o IdentityFile="$key" \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    -o LogLevel=VERBOSE \
    -p "$dest_port" \
    -T \
    "${dest_user}@${dest_host}" true >/dev/null 2>"$verb" || auth_rc=$?
  method=$(perl -ne '
    if (/using "([a-z0-9-]+)"/) { $got = $1 }
    if (/Permission denied/) { $denied = 1 }
    END {
      if (defined $got && length $got) { print $got }
      elsif ($denied) { print "denied" }
    }
  ' "$verb" 2>/dev/null || true)
fi
rm -f "$verb" "$key" "$key.pub"
unset dest_user dest_host dest_port
case "$method" in
  none | publickey | password | keyboard-interactive | hostbased | denied) ;;
  *) method=unknown ;;
esac
note "auth_method=$method"
if [[ "$method" == none ]]; then
  note "operator_auth=none"
  note "boundary: the operator endpoint answers auth method none because the tailnet identity is already accepted. A second key is not that client boundary."
elif [[ "$method" == publickey && "$auth_rc" -eq 0 ]]; then
  fail "a second key was accepted"
elif [[ "$method" == denied && "$auth_rc" -ne 0 ]]; then
  pass "a second key was refused"
elif [[ "$method" == publickey && "$auth_rc" -ne 0 ]]; then
  pass "a second key was refused"
else
  fail "second-key attempt did not prove a refusal"
fi

# The revocable export is the run listener: one key, public-key auth only.
# Operator ssh is left alone. State stays under the raw directory, not in evidence.
# The probe is a function so a case pattern's ")" is not inside $( ).
b7_listener_down() {
  if [[ -n "${B7_LISTENER_STATE:-}" && -f "${B7_LISTENER_STATE}" ]]; then
    RW_RUN_SSHD_STATE="$B7_LISTENER_STATE" RW_SSH_TARGET="$RW_SSH_TARGET" \
      "$(proof_root)/src/run-sshd.sh" down >/dev/null 2>&1 || true
  fi
}
b7_probe_listener() {
  local verb none_method key verb2 second_rc
  # shellcheck disable=SC1090
  . "$B7_LISTENER_STATE"
  verb=$(mktemp "${RW_RAW}/b7-none.XXXXXX")
  SSH_AUTH_SOCK='' ssh -F /dev/null \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o IdentityFile=/dev/null \
    -o PreferredAuthentications=none \
    -o PubkeyAuthentication=no \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    -o LogLevel=VERBOSE \
    -p "$RUN_PORT" \
    -T \
    "${RUN_USER}@${RUN_HOST}" true >/dev/null 2>"$verb" || true
  none_method=$(perl -ne '
    if (/using "([a-z0-9-]+)"/) { $got = $1 }
    if (/Permission denied/) { $denied = 1 }
    if (/Bad configuration option/ || /Unsupported/) { $bad = 1 }
    END {
      if (defined $got && length $got) { print $got }
      elsif ($denied) { print "denied" }
      elsif ($bad) { print "client-rejected" }
    }
  ' "$verb" 2>/dev/null || true)
  rm -f "$verb"
  key=$(mktemp "${RW_RAW}/b7-key.XXXXXX")
  rm -f "$key"
  ssh-keygen -t ed25519 -N "" -q -f "$key" </dev/null
  verb2=$(mktemp "${RW_RAW}/b7-second.XXXXXX")
  # rw-raw-ssh-rc-ok: login probe running `true`; the status is the login result (255 on refusal), not a remote command's status
  second_rc=0
  SSH_AUTH_SOCK='' ssh -F /dev/null \
    -i "$key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 \
    -o LogLevel=ERROR \
    -p "$RUN_PORT" \
    -T \
    "${RUN_USER}@${RUN_HOST}" true >/dev/null 2>"$verb2" || second_rc=$?
  rm -f "$verb2" "$key" "$key.pub"
  case "$none_method" in
    none | publickey | password | keyboard-interactive | hostbased | denied | client-rejected) ;;
    *) none_method=unknown ;;
  esac
  printf 'none_method=%s second_rc=%s\n' "$none_method" "$second_rc"
}
trap 'b7_listener_down; plane_cleanup' EXIT
B7_LISTENER_STATE="${RW_RAW}/b7-run-sshd.env"
rm -f "$B7_LISTENER_STATE"
if RW_RUN_SSHD_STATE="$B7_LISTENER_STATE" RW_SSH_TARGET="$RW_SSH_TARGET" \
  "$(proof_root)/src/run-sshd.sh" up >"${RW_RAW}/b7-up.out" 2>"${RW_RAW}/b7-up.err"; then
  pass "run listener started"
else
  fail "run listener did not start"
fi
if [[ -f "$B7_LISTENER_STATE" ]]; then
  if RW_RUN_SSHD_STATE="$B7_LISTENER_STATE" "$(proof_root)/src/run-sshd.sh" check-nokey \
    >"${RW_RAW}/b7-nokey.out" 2>"${RW_RAW}/b7-nokey.err"; then
    pass "run listener refused a session with no key"
  else
    fail "run listener accepted a session with no key"
  fi
  listener_line=$(b7_probe_listener)
  none_method=${listener_line%% *}
  none_method=${none_method#none_method=}
  second_rc=${listener_line##* }
  second_rc=${second_rc#second_rc=}
  note "listener_auth=$none_method"
  if [[ "$none_method" == none ]]; then
    fail "run listener accepted auth method none"
  elif [[ "$none_method" == denied ]]; then
    pass "run listener refused auth method none"
  else
    fail "run listener auth method was not a refusal"
  fi
  if [[ "$second_rc" != 0 ]]; then
    pass "run listener refused a second key"
  else
    fail "run listener accepted a second key"
  fi
fi
b7_listener_down
B7_LISTENER_STATE=""

uid=$(proof_ssh 'id -u' || true)
uid=$(printf '%s' "$uid" | tr -d '\r\n')
if [[ "$uid" != "0" && -n "$uid" ]]; then
  pass "remote uid is not root"
else
  fail "remote uid is root"
fi
if proof_ssh 'sudo -n true' >/dev/null 2>&1; then
  note "sudo_n=allowed"
else
  note "sudo_n=refused"
fi
if proof_ssh "command -v exportfs >/dev/null 2>&1 && exportfs -v 2>/dev/null | grep -F -- $(printf '%q' "$RW_REMOTE_ROOT")"; then
  fail "an export lists the scratch directory"
else
  pass "no export lists the scratch directory"
fi

proof_ssh "rm -rf -- $(printf '%q' "$sib")" >/dev/null 2>&1 || true
proof_finish b7
