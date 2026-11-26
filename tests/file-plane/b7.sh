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
  fail "transport accepted method none, so a second key is not a client boundary"
elif [[ "$method" == publickey && "$auth_rc" -eq 0 ]]; then
  fail "a second key was accepted"
elif [[ "$method" == denied && "$auth_rc" -ne 0 ]]; then
  pass "a second key was refused"
elif [[ "$method" == publickey && "$auth_rc" -ne 0 ]]; then
  pass "a second key was refused"
else
  fail "second-key attempt did not prove a refusal"
fi

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
