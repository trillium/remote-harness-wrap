#!/bin/bash
# E5. Teardown removes the run key, the scratch tree, and the broker.
# An access test with the removed key must fail. Exports and mounts of the
# scratch path must be gone. A host that opens a session with no key cannot
# pass: deleting a key would not revoke access, so no extra key is installed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
sec_begin "$@"

E5_NONCE="e5${RW_SEC_NONCE}"
E5_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rw-e5.XXXXXX")
E5_KEY="${E5_DIR}/id_ed25519"
E5_INSTALLED=0

e5_restore_server() {
  [[ "$E5_INSTALLED" -eq 1 ]] || return 0
  exec_ssh python3 - "$E5_NONCE" <<'PY' >/dev/null 2>&1 || true
import os, pathlib, sys
nonce = sys.argv[1]
ak = pathlib.Path.home() / ".ssh" / "authorized_keys"
bak = pathlib.Path(str(ak) + ".rw-e5-" + nonce)
if bak.exists():
    os.replace(bak, ak)
    try:
        ak.chmod(0o600)
    except OSError:
        pass
PY
  E5_INSTALLED=0
}

e5_remove_runtime() {
  if [[ -n "${RW_REMOTE_ROOT:-}" ]]; then
    exec_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT")" >/dev/null 2>&1 || true
  fi
  exec_stop_broker
  exec_master_exit
  rm -f "$E5_KEY" "$E5_KEY.pub"
  rm -rf "$E5_DIR"
}

e5_teardown() {
  e5_restore_server
  if [[ -n "${RW_RUN_SSHD_STATE:-}" && -f "$RW_RUN_SSHD_STATE" ]]; then
    RW_RUN_SSHD_STATE="$RW_RUN_SSHD_STATE" "$(exec_root)/src/run-sshd.sh" down >/dev/null 2>&1 || true
  fi
  e5_remove_runtime
}
RW_EXTRA_CLEAN="e5_teardown"
export RW_EXTRA_CLEAN

# Resolve the endpoint the same way for every probe. A config passed with
# -F hides the operator's HostName, and a failed lookup is not a refusal.
host=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
user=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null | awk '$1=="user"{print $2; exit}')
if [[ -z "$host" || -z "$user" ]]; then
  fail "could not resolve the operator endpoint"
  can_revoke=0
else
  nokey_cfg=$(mktemp "${TMPDIR:-/tmp}/rw-e5-nokey.XXXXXX")
  chmod 600 "$nokey_cfg"
  cat >"$nokey_cfg" <<EOF
Host probe
  HostName ${host}
  User ${user}
  IdentitiesOnly yes
  IdentityFile /dev/null
  IdentityAgent none
  PreferredAuthentications publickey
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  NumberOfPasswordPrompts 0
  StrictHostKeyChecking yes
  UserKnownHostsFile ${HOME}/.ssh/known_hosts
  GlobalKnownHostsFile /dev/null
  ControlMaster no
  ControlPath /tmp/rw-sec-e5nokey-${RW_SEC_NONCE}-%C
  ForwardAgent no
  GSSAPIAuthentication no
  HostbasedAuthentication no
  BatchMode yes
EOF
  nokey_out=$(mktemp "${TMPDIR:-/tmp}/rw-e5-nokey.XXXXXX")
  # rw-raw-ssh-rc-ok: login probe running `true`; the status is the login result (255 on refusal), not a remote command's status
  SSH_AUTH_SOCK='' ssh -v -F "$nokey_cfg" -o ConnectTimeout=8 -T probe 'printf NOKEY_SESSION\n' >"$nokey_out" 2>"${RW_RAW}/e5-nokey.err"
  nokey_rc=$?
  rm -f "$nokey_cfg"
  if grep -F -q 'using "none"' "${RW_RAW}/e5-nokey.err"; then
    note "operator_auth=none"
  fi
  if grep -F -q 'NOKEY_SESSION' "$nokey_out"; then
    note "unauthenticated_session=yes exit=${nokey_rc}"
    note "operator endpoint accepts a session with no run key"
    can_revoke=2
  else
    note "unauthenticated_session=no exit=${nokey_rc}"
    pass "a session does not open with no key"
    can_revoke=1
  fi
  rm -f "$nokey_out"
fi

# The operator sshd ignores authorized_keys. Revoke a listener that
# accepts only the run key, then prove that key can no longer connect.
if [[ "${can_revoke:-0}" -eq 2 ]]; then
  run_bin="$(exec_root)/src/run-sshd.sh"
  RW_RUN_SSHD_STATE="${RW_RAW}/run-sshd.env"
  export RW_RUN_SSHD_STATE
  if "$run_bin" up >"${RW_RAW}/run-sshd-up.out" 2>"${RW_RAW}/run-sshd-up.err"; then
    pass "run listener started"
  else
    fail "could not start the run listener"
  fi
  if "$run_bin" check >"${RW_RAW}/run-sshd-check.out" 2>"${RW_RAW}/run-sshd-check.err"; then
    pass "run key opened a session before teardown"
  else
    fail "run key did not open a session"
  fi
  if "$run_bin" check-nokey >"${RW_RAW}/run-sshd-nokey.out" 2>"${RW_RAW}/run-sshd-nokey.err"; then
    pass "run listener refused a session with no key"
  else
    fail "run listener accepted a session with no key"
  fi
  if "$run_bin" down >"${RW_RAW}/run-sshd-down.out" 2>"${RW_RAW}/run-sshd-down.err" \
    && grep -F -q 'LISTENER=gone' "${RW_RAW}/run-sshd-down.out"; then
    pass "removed key did not open a session"
  else
    fail "access continued after the run key was removed"
  fi
  if [[ -f "$RW_RUN_SSHD_STATE" ]]; then
    fail "run listener state still exists"
  else
    pass "run listener state is gone"
  fi
  can_revoke=0
fi

if [[ "$can_revoke" -eq 1 ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "rw-${E5_NONCE}" -f "$E5_KEY"
  src=$(exec_ssh 'printf %s "$SSH_CONNECTION"' | awk '{print $1}')
  if [[ -z "$src" ]]; then
    fail "could not learn the connection source"
  else
    pub=$(awk '{print $1 " " $2}' "$E5_KEY.pub")
    line="restrict,from=\"${src}\",command=\"printf rw-e5-ok\" ${pub}"
    install_script=$(mktemp "${TMPDIR:-/tmp}/rw-e5-inst.XXXXXX")
    chmod 600 "$install_script"
    LINE="$line" NONCE="$E5_NONCE" python3 - "$install_script" <<'PY'
import json, os, sys
path = sys.argv[1]
script = (
    "import pathlib\n"
    "line = " + json.dumps(os.environ["LINE"]) + "\n"
    "nonce = " + json.dumps(os.environ["NONCE"]) + "\n"
    "sshdir = pathlib.Path.home() / '.ssh'\n"
    "sshdir.mkdir(mode=0o700, exist_ok=True)\n"
    "ak = sshdir / 'authorized_keys'\n"
    "bak = pathlib.Path(str(ak) + '.rw-e5-' + nonce)\n"
    "if not bak.exists():\n"
    "    bak.write_bytes(ak.read_bytes() if ak.exists() else b'')\n"
    "    bak.chmod(0o600)\n"
    "current = ak.read_text() if ak.exists() else ''\n"
    "if current and not current.endswith('\\n'):\n"
    "    current += '\\n'\n"
    "current += line + '\\n'\n"
    "ak.write_text(current)\n"
    "ak.chmod(0o600)\n"
    "print('installed')\n"
)
open(path, "w").write(script)
PY
    installed=$(exec_ssh python3 - <"$install_script" || true)
    rm -f "$install_script"
    if [[ "$installed" == installed ]]; then
      E5_INSTALLED=1
      pass "ephemeral key installed"
    else
      fail "ephemeral key was not installed"
    fi
  fi

  if [[ "$E5_INSTALLED" -eq 1 ]]; then
    key_cfg=$(mktemp "${TMPDIR:-/tmp}/rw-e5-cfg.XXXXXX")
    chmod 600 "$key_cfg"
    cat >"$key_cfg" <<EOF
Host peer
  HostName ${host}
  User ${user}
  IdentitiesOnly yes
  IdentityFile ${E5_KEY}
  IdentityAgent none
  PreferredAuthentications publickey
  PubkeyAuthentication yes
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  NumberOfPasswordPrompts 0
  GSSAPIAuthentication no
  HostbasedAuthentication no
  StrictHostKeyChecking yes
  UserKnownHostsFile ${HOME}/.ssh/known_hosts
  GlobalKnownHostsFile /dev/null
  ControlMaster no
  ControlPath /tmp/rw-sec-e5key-${RW_SEC_NONCE}-%C
  BatchMode yes
EOF
    key_out=$(mktemp "${TMPDIR:-/tmp}/rw-e5-key.XXXXXX")
    SSH_AUTH_SOCK='' ssh -F "$key_cfg" -o ConnectTimeout=8 -T peer 'printf SHOULD_BE_FORCED\n' >"$key_out" 2>"${RW_RAW}/e5-before.err" || true
    if grep -F -q 'rw-e5-ok' "$key_out"; then
      pass "ephemeral key opened a restricted session before teardown"
    elif grep -F -q 'SHOULD_BE_FORCED' "$key_out"; then
      note "unrestricted_session=yes"
      fail "a session opened without the ephemeral key restriction"
    else
      fail "ephemeral key did not open a session"
    fi
    rm -f "$key_out"

    e5_restore_server
    key_out=$(mktemp "${TMPDIR:-/tmp}/rw-e5-key.XXXXXX")
    SSH_AUTH_SOCK='' ssh -F "$key_cfg" -o ConnectTimeout=8 -T peer 'printf SHOULD_NOT_RUN\n' >"$key_out" 2>"${RW_RAW}/e5-after.err" || true
    if grep -F -q 'rw-e5-ok' "$key_out" || grep -F -q 'SHOULD_NOT_RUN' "$key_out"; then
      fail "access continued after the run key was removed"
    else
      pass "removed key did not open a session"
    fi
    rm -f "$key_out" "$key_cfg"
  fi
fi

e5_remove_runtime
if [[ -f "$E5_KEY" ]]; then
  fail "private key still exists after teardown"
else
  pass "private key is gone"
fi

exp=$(exec_ssh 'if command -v exportfs >/dev/null 2>&1; then exportfs -v 2>/dev/null || true; else printf "exportfs-absent\n"; fi' || true)
if printf '%s\n' "$exp" | grep -F -q 'exportfs-absent'; then
  pass "no export tool left a scratch export"
elif printf '%s\n' "$exp" | grep -F -q -- "$RW_REMOTE_ROOT"; then
  fail "scratch path is still exported"
else
  pass "scratch path is not exported"
fi
if mount | grep -F -q -- "$RW_REMOTE_ROOT"; then
  fail "scratch path is still mounted on the provider"
else
  pass "scratch path is not mounted on the provider"
fi
if exec_ssh "[[ -d $(printf '%q' "$RW_BROKER_ROOT") ]]"; then
  fail "broker directory still exists"
else
  pass "broker directory is gone"
fi
if exec_ssh "[[ -d $(printf '%q' "$RW_REMOTE_ROOT") ]]"; then
  fail "remote scratch still exists"
else
  pass "remote scratch is gone"
fi
if exec_ssh true; then
  pass "the operator key still connects after teardown"
else
  fail "teardown broke the operator key"
fi
exec_finish e5
