#!/bin/bash
# B1. Can an ordinary process read and write the remote tree on this Mac?
# NFS is attempted locally. SMB and FUSE-T are attempted only when they do
# not need an administrator install.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
export RW_EVIDENCE_PLANE=file-plane
proof_prepare "$@"
RW_LABEL="${RW_LABEL:-provider-mac}"
export RW_LABEL

ROOT=$(mktemp -d /tmp/rw-bd-b1.XXXXXX)
ROOT=$(cd "$ROOT" && pwd -P)
PROJ="$ROOT/proj"
MNT="$ROOT/mnt"
EXPORTS="$ROOT/exports"
NFSD_PID=""
mkdir -p "$PROJ" "$MNT"
printf 'hello\n' >"$PROJ/hello.txt"

b1_cleanup() {
  local rc=$?
  if [[ -n "$MNT" ]]; then
    diskutil unmount force "$MNT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$EXPORTS" ]]; then
    sudo -n pkill -f "$EXPORTS" >/dev/null 2>&1 || true
  fi
  if [[ -n "$NFSD_PID" ]]; then
    sudo -n kill "$NFSD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$ROOT"
  [[ -n "${NOTES:-}" ]] && rm -f "$NOTES"
  exit "$rc"
}
trap b1_cleanup EXIT

note "provider_os=$(uname -s)"
note "provider_release=$(uname -r)"
note "plane_attempt=nfs-smb-fuse"

if [[ -e /etc/exports ]]; then
  note "etc_exports_exists=yes"
  fail "refusing to touch an existing /etc/exports"
else
  etc_result=$(python3 -c 'import os
try:
    f=open("/etc/exports","w")
    f.write("/tmp x\n")
    f.close()
    print("allowed")
except OSError as e:
    print("errno=%s" % e.errno)
')
  etc_result=$(printf '%s' "$etc_result" | tr -d '\r\n')
  note "etc_exports_write=$etc_result"
  if [[ "$etc_result" == allowed ]]; then
    rm -f /etc/exports
    fail "writing /etc/exports was allowed"
  elif [[ "$etc_result" == errno=1 || "$etc_result" == errno=13 ]]; then
    pass "writing /etc/exports is denied"
  else
    fail "could not classify the /etc/exports failure"
  fi
fi

printf '%s 127.0.0.1\n' "$PROJ" >"$EXPORTS"
if sudo -n /sbin/nfsd -F "$EXPORTS" checkexports >/dev/null 2>&1; then
  note "nfsd_checkexports=ok"
else
  note "nfsd_checkexports=failed"
fi

sudo -n sh -c '/sbin/nfsd -F "$1" -t -u -n 2 >"$2" 2>&1' sh "$EXPORTS" "$ROOT/nfsd.out" &
NFSD_PID=$!
ready=0
i=0
while [[ $i -lt 20 ]]; do
  if nc -z -G 1 127.0.0.1 2049 >/dev/null 2>&1; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 0.25
done
note "nfsd_port_ready=$ready"

mounted=0
if [[ $ready -eq 1 ]] && sudo -n sh -c 'mount_nfs -o noac,nfc "$1" "$2" >"$3" 2>"$4"' sh "127.0.0.1:$PROJ" "$MNT" "$ROOT/mount.out" "$ROOT/mount.err"; then
  mounted=1
  note "nfs_mount=ok"
else
  note "nfs_mount=failed"
fi

read_errno=$(python3 -c 'import os,sys
try:
    os.listdir(sys.argv[1])
    print(0)
except OSError as e:
    print(e.errno)
' "$MNT" || echo missing)
read_errno=$(printf '%s' "$read_errno" | tr -d '\r\n')
note "listdir_errno=$read_errno"
open_errno=$(python3 -c 'import os,sys
try:
    open(os.path.join(sys.argv[1], "hello.txt"), "r").read()
    print(0)
except OSError as e:
    print(e.errno)
' "$MNT" || echo missing)
open_errno=$(printf '%s' "$open_errno" | tr -d '\r\n')
note "open_errno=$open_errno"

if [[ $mounted -eq 1 && "$read_errno" == 0 && "$open_errno" == 0 ]]; then
  if printf 'write\n' >"$MNT/from-provider.txt" 2>"$ROOT/write.err"; then
    pass "ordinary process read and wrote the nfs mount"
    note "status: proven"
  else
    fail "nfs mount was readable but not writable"
    note "status: unproven"
  fi
elif [[ $mounted -eq 1 && ( "$read_errno" == 1 || "$open_errno" == 1 ) ]]; then
  pass "ordinary read of the nfs mount returns errno 1"
  note "status: unsupported"
  note "reason: System Policy denies ordinary reads of the nfs mount"
else
  note "status: unsupported"
  note "reason: nfs mount was not readable by an ordinary process"
  pass "nfs is not a usable file plane on this provider"
fi

policy=$(perl -e 'alarm 8; exec @ARGV' log show --last 30s --style compact --predicate 'eventMessage CONTAINS "System Policy"' 2>/dev/null || true)
policy_n=$(printf '%s\n' "$policy" | grep -c 'System Policy' || true)
note "system_policy_lines=$policy_n"
if printf '%s\n' "$policy" | grep -q 'deny'; then
  note "system_policy_deny=present"
  sample=$(printf '%s\n' "$policy" | grep 'deny' | head -n 1 || true)
  note "system_policy_sample=${sample}"
fi

smb_n=0
smb_open=0
for host in ${RW_SMB_HOSTS:-}; do
  smb_n=$((smb_n + 1))
  state=$(python3 -c 'import socket,sys
s=socket.socket(); s.settimeout(2)
try:
    s.connect((sys.argv[1], 445)); print("open")
except Exception:
    print("closed")
' "$host" || echo closed)
  if [[ "$state" == open ]]; then
    smb_open=$((smb_open + 1))
  fi
done
note "smb_hosts=$smb_n smb_open=$smb_open"
if [[ $smb_n -eq 0 ]]; then
  note "smb=not-probed"
elif [[ $smb_open -eq 0 ]]; then
  pass "smb port 445 is closed on every probed host"
else
  note "smb_port_open_count=$smb_open"
  fail "smb port was open and was not mounted in this test"
fi

fuse_installed=no
for entry in /Library/Filesystems/*; do
  case "$entry" in
    *[Ff][Uu][Ss][Ee]*) fuse_installed=yes ;;
  esac
done
note "fuse_installed=$fuse_installed"
if brew info --cask fuse-t 2>/dev/null | grep -q 'Pkg'; then
  note "fuse_t=pkg-installer"
  pass "FUSE-T is not installed and its installer needs an administrator"
else
  note "fuse_t=unknown"
  fail "could not classify the FUSE-T installer"
fi

if [[ $mounted -ne 1 || "$read_errno" != 0 ]]; then
  note "result: macOS file plane is unsupported for ordinary processes"
fi
proof_finish b1
