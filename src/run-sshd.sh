#!/bin/bash
# Run-scoped sshd.
#
# Some peers accept the operator's network identity and never consult
# authorized_keys (Tailscale SSH answers auth method "none"). Deleting a
# line from authorized_keys does not revoke that session. A run that must
# be revocable gets its own listener, one key, and public-key auth only.
# down kills the listener and deletes the key. The operator's own ssh
# endpoint is left alone.
#
#   run-sshd.sh up
#   run-sshd.sh check          # exit 0 when the run key gets a session
#   run-sshd.sh check-closed   # exit 0 when that key does not
#   run-sshd.sh down
#
# State stays in RW_RUN_SSHD_STATE (default /tmp/rw-run-sshd.env).
# Nothing here is written into the repository.
set -u

STATE="${RW_RUN_SSHD_STATE:-/tmp/rw-run-sshd.env}"

die() {
  printf 'run-sshd: %s\n' "$*" >&2
  exit 2
}

load_state() {
  [[ -f "$STATE" ]] || die "no run listener state"
  # shellcheck disable=SC1090
  . "$STATE"
  [[ -n "${RUN_HOST:-}" && -n "${RUN_PORT:-}" && -n "${RUN_USER:-}" ]] || die "incomplete state"
}

ssh_operator() {
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="${RW_CONNECT_TIMEOUT:-8}" \
    -o LogLevel=ERROR \
    -T \
    "$RW_SSH_TARGET" \
    "$@"
}

cmd_up() {
  [[ -n "${RW_SSH_TARGET:-}" ]] || die "RW_SSH_TARGET is unset"
  [[ ! -f "$STATE" ]] || die "a run listener is already recorded"
  local work pub host user nonce remote_dir
  work=$(mktemp -d "${TMPDIR:-/tmp}/rw-run-sshd.XXXXXX")
  chmod 700 "$work"
  ssh-keygen -q -t ed25519 -N "" -C "rw-run-sshd" -f "$work/id_ed25519"
  pub=$(awk '{print $1 " " $2}' "$work/id_ed25519.pub")
  host=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')
  user=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null | awk '$1=="user"{print $2; exit}')
  [[ -n "$host" && -n "$user" ]] || die "could not resolve the operator endpoint"
  nonce="rwsshd${RANDOM}${RANDOM}"
  remote_dir="/tmp/${nonce}"
  local answer payload
  # One argument. The remote shell splits spaces, and a public key has one.
  payload=$(printf '%s\n%s' "$pub" "$remote_dir" | base64 | tr -d '\n')
  answer=$(ssh_operator python3 - "$payload" <<'PY'
import base64, os, pathlib, socket, subprocess, sys
raw = base64.b64decode(sys.argv[1]).decode()
pub, remote_dir = raw.split("\n", 1)
root = pathlib.Path(remote_dir)
if root.exists():
    sys.exit("remote dir exists")
root.mkdir(mode=0o700)
subprocess.check_call(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "host")], stdout=subprocess.DEVNULL)
os.chmod(root / "host", 0o600)
(root / "ak").write_text(pub + "\n")
os.chmod(root / "ak", 0o600)
conn = os.environ.get("SSH_CONNECTION", "")
parts = conn.split()
if len(parts) < 3:
    sys.exit("no SSH_CONNECTION")
listen = parts[2]
sock = socket.socket()
sock.bind((listen, 0))
port = sock.getsockname()[1]
sock.close()
cfg = """Port {port}
ListenAddress {listen}
HostKey {hostkey}
PidFile {pid}
AuthorizedKeysFile {ak}
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
StrictModes no
PrintMotd no
PrintLastLog no
X11Forwarding no
AllowTcpForwarding no
GatewayPorts no
""".format(port=port, listen=listen, hostkey=root / "host", pid=root / "sshd.pid", ak=root / "ak")
(root / "sshd_config").write_text(cfg)
log = root / "sshd.log"
proc = subprocess.run(
    ["/usr/sbin/sshd", "-f", str(root / "sshd_config"), "-E", str(log)],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
if proc.returncode != 0:
    sys.stderr.write(log.read_text() if log.exists() else "sshd failed\n")
    sys.exit(proc.returncode)
hostpub = (root / "host.pub").read_text().strip()
sys.stdout.write("PORT={port}\nLISTEN={listen}\nHOSTPUB={hostpub}\n".format(port=port, listen=listen, hostpub=hostpub))
PY
  ) || {
    rm -rf "$work"
    ssh_operator "rm -rf -- $(printf '%q' "$remote_dir")" >/dev/null 2>&1 || true
    die "could not start the run listener"
  }
  local port="" listen="" hostpub=""
  port=$(printf '%s\n' "$answer" | sed -n 's/^PORT=//p')
  listen=$(printf '%s\n' "$answer" | sed -n 's/^LISTEN=//p')
  hostpub=$(printf '%s\n' "$answer" | sed -n 's/^HOSTPUB=//p')
  [[ -n "$port" && -n "$listen" && -n "$hostpub" ]] || die "run listener did not report a port"
  local known="$work/known_hosts"
  printf '[%s]:%s %s\n' "$listen" "$port" "$hostpub" >"$known"
  chmod 600 "$known"
  umask 077
  {
    printf 'RUN_HOST=%q\n' "$listen"
    printf 'RUN_PORT=%q\n' "$port"
    printf 'RUN_USER=%q\n' "$user"
    printf 'RUN_KEY=%q\n' "$work/id_ed25519"
    printf 'RUN_KNOWN=%q\n' "$known"
    printf 'RUN_WORK=%q\n' "$work"
    printf 'RUN_REMOTE_DIR=%q\n' "$remote_dir"
    printf 'RW_SSH_TARGET=%q\n' "$RW_SSH_TARGET"
  } >"$STATE"
  chmod 600 "$STATE"
  printf 'LISTENER=up\n'
}

run_ssh() {
  local key_mode="$1"
  shift
  load_state
  local -a ident=()
  if [[ "$key_mode" == key ]]; then
    ident=(-i "$RUN_KEY")
  else
    ident=(-o IdentityFile=/dev/null)
  fi
  SSH_AUTH_SOCK='' ssh "${ident[@]}" \
    -o IdentitiesOnly=yes \
    -o IdentityAgent=none \
    -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=${RUN_KNOWN}" \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    -o LogLevel=ERROR \
    -p "$RUN_PORT" \
    -T \
    "${RUN_USER}@${RUN_HOST}" \
    "$@"
}

cmd_check() {
  local out
  out=$(run_ssh key 'printf RUN_OK\n' 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -F -q 'RUN_OK'; then
    printf 'CHECK=open\n'
    exit 0
  fi
  printf 'CHECK=closed\n'
  exit 1
}

cmd_check_closed() {
  local out
  out=$(run_ssh key 'printf RUN_OK\n' 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -F -q 'RUN_OK'; then
    printf 'CHECK=open\n'
    exit 1
  fi
  printf 'CHECK=closed\n'
  exit 0
}

cmd_check_nokey() {
  local out
  out=$(run_ssh nokey 'printf RUN_OK\n' 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -F -q 'RUN_OK'; then
    printf 'NOKEY=open\n'
    exit 1
  fi
  printf 'NOKEY=closed\n'
  exit 0
}

cmd_down() {
  [[ -f "$STATE" ]] || {
    printf 'LISTENER=absent\n'
    exit 0
  }
  # shellcheck disable=SC1090
  . "$STATE"
  local target="${RW_SSH_TARGET:-}"
  if [[ -n "$target" && -n "${RUN_REMOTE_DIR:-}" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout="${RW_CONNECT_TIMEOUT:-8}" -o LogLevel=ERROR -T "$target" \
      "if [[ -f $(printf '%q' "${RUN_REMOTE_DIR}/sshd.pid") ]]; then kill \$(cat $(printf '%q' "${RUN_REMOTE_DIR}/sshd.pid")) 2>/dev/null || true; sleep 0.2; kill -KILL \$(cat $(printf '%q' "${RUN_REMOTE_DIR}/sshd.pid")) 2>/dev/null || true; fi; rm -rf -- $(printf '%q' "$RUN_REMOTE_DIR")" \
      >/dev/null 2>&1 || true
  fi
  # Prove the saved endpoint no longer returns a session, then drop the key.
  if [[ -n "${RUN_HOST:-}" && -n "${RUN_PORT:-}" && -n "${RUN_USER:-}" && -n "${RUN_KEY:-}" && -f "${RUN_KEY:-}" ]]; then
    local out
    out=$(SSH_AUTH_SOCK='' ssh -i "$RUN_KEY" \
      -o IdentitiesOnly=yes -o IdentityAgent=none \
      -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o BatchMode=yes -o StrictHostKeyChecking=yes \
      -o "UserKnownHostsFile=${RUN_KNOWN}" -o GlobalKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o LogLevel=ERROR \
      -p "$RUN_PORT" -T "${RUN_USER}@${RUN_HOST}" 'printf RUN_OK\n' 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -F -q 'RUN_OK'; then
      printf 'LISTENER=still-open\n'
      exit 1
    fi
  fi
  rm -rf "${RUN_WORK:-}"
  rm -f "$STATE"
  printf 'LISTENER=gone\n'
}

sub=${1:-}
case "$sub" in
  up) cmd_up ;;
  check) cmd_check ;;
  check-closed) cmd_check_closed ;;
  check-nokey) cmd_check_nokey ;;
  down) cmd_down ;;
  *) die "usage: run-sshd.sh up|check|check-closed|check-nokey|down" ;;
esac
