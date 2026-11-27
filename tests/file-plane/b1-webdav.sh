#!/bin/bash
# B1 over WebDAV. Can an ordinary process on the provider Mac read and write the
# remote tree through a mount that needs no administrator?
#
#   RW_SSH_TARGET=<ssh-host> RW_WSGIDAV_LIB=<dir holding wsgidav> tests/file-plane/b1-webdav.sh
#
# The remote runs a WebDAV server bound to its loopback address. An ssh
# forward carries it to the provider loopback address. The provider runs
# mount_webdav as the ordinary user onto a directory that user owns.
# RW_WSGIDAV_LIB is a directory of pure-python packages (wsgidav, cheroot and
# their dependencies, for example a venv site-packages). It is copied to the
# remote scratch directory, so the remote needs only python3.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
export RW_EVIDENCE_PLANE=file-plane
proof_prepare "$@"
RW_LABEL="${RW_LABEL:-provider-mac}"
export RW_LABEL
RW_SSH_TARGET="${RW_SSH_TARGET:-}"
[[ -n "$RW_SSH_TARGET" ]] || {
  printf 'b1-webdav: set RW_SSH_TARGET\n' >&2
  exit 2
}
LIB="${RW_WSGIDAV_LIB:-}"
[[ -n "$LIB" && -d "$LIB/wsgidav" ]] || {
  printf 'b1-webdav: set RW_WSGIDAV_LIB to a directory holding wsgidav\n' >&2
  exit 2
}

ROOT=$(mktemp -d /tmp/rw-bd-b1w.XXXXXX)
ROOT=$(cd "$ROOT" && pwd -P)
MNT="$ROOT/mnt"
mkdir -p "$MNT"
RROOT="/tmp/rw-bd-b1w-${RANDOM}${RANDOM}"
RPORT=$((20000 + RANDOM % 10000))
LPORT=$((30000 + RANDOM % 10000))
TUNNEL_PID=""
MOUNTED=0

q() { printf '%q' "$1"; }

b1w_cleanup() {
  local rc=$?
  if [[ $MOUNTED -eq 1 ]]; then
    umount "$MNT" >/dev/null 2>&1 || diskutil unmount force "$MNT" >/dev/null 2>&1 || true
  fi
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" >/dev/null 2>&1
  proof_ssh "[ -f $(q "$RROOT")/pid ] && kill \$(cat $(q "$RROOT")/pid) 2>/dev/null; rm -rf -- $(q "$RROOT")" >/dev/null 2>&1 || true
  proof_ssh_exit
  rm -rf "$ROOT"
  [[ -n "${NOTES:-}" ]] && rm -f "$NOTES"
  exit "$rc"
}
trap b1w_cleanup EXIT

RW_REMOTE_NAME=$(proof_ssh hostname 2>/dev/null | tr -d '\r\n' || true)
export RW_REMOTE_NAME
note "provider_os=$(uname -s)"
note "provider_uid_is_root=$([[ $(id -u) -eq 0 ]] && echo yes || echo no)"
note "plane_attempt=webdav-over-ssh-forward"
note "remote_os=$(proof_ssh uname -s 2>/dev/null | tr -d '\r\n')"

proof_ssh "mkdir -p $(q "$RROOT")/proj $(q "$RROOT")/lib && printf 'remote-owned\n' >$(q "$RROOT")/proj/hello.txt"
tar -C "$LIB" --exclude='*.so' --exclude=__pycache__ -cf - . 2>/dev/null |
  proof_ssh "tar -C $(q "$RROOT")/lib -xf - 2>/dev/null"
proof_ssh "cd $(q "$RROOT") && (PYTHONPATH=$(q "$RROOT")/lib nohup python3 -c 'from wsgidav.server.server_cli import run; run()' --host 127.0.0.1 --port $RPORT --root $(q "$RROOT")/proj --auth anonymous >log 2>&1 & echo \$! >pid)"
up=0
for _ in $(seq 1 20); do
  code=$(proof_ssh "curl -s -o /dev/null -w '%{http_code}' -X PROPFIND http://127.0.0.1:$RPORT/" 2>/dev/null || true)
  if [[ "$code" == 207 ]]; then
    up=1
    break
  fi
  sleep 0.5
done
note "remote_webdav_bound_to_loopback=$up"
if [[ $up -eq 1 ]]; then
  pass "the remote WebDAV server answers on its loopback address"
else
  fail "the remote WebDAV server did not start"
fi

ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -o LogLevel=ERROR -N \
  -L "127.0.0.1:$LPORT:127.0.0.1:$RPORT" "$RW_SSH_TARGET" &
TUNNEL_PID=$!
tun=0
for _ in $(seq 1 20); do
  if nc -z -G 1 127.0.0.1 "$LPORT" >/dev/null 2>&1; then
    tun=1
    break
  fi
  sleep 0.25
done
note "tunnel_ready=$tun"

if mount_webdav -S "http://127.0.0.1:$LPORT/" "$MNT" >"$ROOT/mount.out" 2>&1; then
  MOUNTED=1
  note "webdav_mount=ok"
  note "mount_needed_sudo=no"
else
  note "webdav_mount=failed"
  note "mount_error=$(tr '\n' ' ' <"$ROOT/mount.out")"
fi

# The test process is an ordinary python3, isolated from site customization.
res=$(python3 -I - "$MNT" <<'PY'
import os, sys
m = sys.argv[1]
out = []
try:
    out.append("listdir=" + ",".join(sorted(n for n in os.listdir(m) if not n.startswith("._"))))
except OSError as e:
    out.append("listdir_errno=%s" % e.errno)
try:
    out.append("read=" + open(os.path.join(m, "hello.txt")).read().strip())
except OSError as e:
    out.append("read_errno=%s" % e.errno)
try:
    with open(os.path.join(m, "from-provider.txt"), "w") as f:
        f.write("provider-wrote\n")
    out.append("write=ok")
except OSError as e:
    out.append("write_errno=%s" % e.errno)
print(";".join(out))
PY
)
note "ordinary_process=$res"
case "$res" in
  *"listdir=hello.txt"*"read=remote-owned"*"write=ok"*)
    pass "an ordinary process listed, read and wrote the mounted remote tree"
    ;;
  *)
    fail "an ordinary process could not list, read and write the mounted remote tree"
    ;;
esac

on_remote=$(proof_ssh "cat $(q "$RROOT")/proj/from-provider.txt" 2>/dev/null | tr -d '\r\n')
note "remote_sees_provider_write=$on_remote"
if [[ "$on_remote" == provider-wrote ]]; then
  pass "the file the provider wrote is in the remote directory"
else
  fail "the provider write did not reach the remote directory"
fi

proof_ssh "printf 'remote-wrote\n' >$(q "$RROOT")/proj/from-remote.txt"
sleep 1
back=$(cat "$MNT/from-remote.txt" 2>/dev/null | tr -d '\r\n')
note "provider_sees_remote_write=$back"
if [[ "$back" == remote-wrote ]]; then
  pass "a file the remote wrote is readable through the mount"
else
  fail "the remote write was not readable through the mount"
fi

# Known limit: the mount is noexec, so programs cannot run from it.
opts=$(mount | grep -F " on $MNT " | sed 's/.*(\(.*\))/\1/')
note "mount_options=$opts"
case "$opts" in
  *noexec*) note "limit: the mount is noexec, so programs cannot run from the mounted tree" ;;
esac

if [[ $MOUNTED -eq 1 && "$res" == *"write=ok"* && "$on_remote" == provider-wrote ]]; then
  note "status: proven"
  note "result: an unprivileged mount of the remote tree is readable and writable on a Mac"
else
  note "status: unsupported"
fi
proof_finish b1-webdav
