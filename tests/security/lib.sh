#!/bin/bash
# Shared helpers for the security proofs. Sourced by tests/security/*.sh.
# A test fails by recording FAIL lines and exiting non-zero.
# Evidence records results, never token values, hostnames, or account names.

sec_exec_lib() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../exec" && pwd
}

# shellcheck source=../exec/lib.sh
. "$(sec_exec_lib)/lib.sh"

# The exec helper's broker cleanup targets a shared directory.
# Security proofs only remove the broker they created.
exec_stop_broker() {
  local root="${RW_BROKER_ROOT:-}"
  case "$root" in
    /tmp/rw-sec-broker-*) ;;
    *) return 0 ;;
  esac
  exec_ssh "if [[ -f $(printf '%q' "$root/broker.pid") ]]; then kill \$(cat $(printf '%q' "$root/broker.pid")) 2>/dev/null || true; fi; rm -rf -- $(printf '%q' "$root")" \
    >/dev/null 2>&1 || true
}

sec_nonce() {
  if [[ -n "${RW_SEC_NONCE:-}" ]]; then
    printf '%s' "$RW_SEC_NONCE"
    return 0
  fi
  od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

sec_prepare() {
  local nonce
  nonce=$(sec_nonce)
  RW_SEC_NONCE="$nonce"
  RW_BROKER_ROOT="${RW_BROKER_ROOT:-/tmp/rw-sec-broker-${nonce}}"
  RW_CONTROL_PATH="${RW_CONTROL_PATH:-/tmp/rw-sec-${nonce}-%C}"
  RW_EVIDENCE="${RW_EVIDENCE:-$(exec_root)/evidence/security}"
  RW_RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-sec-proof-raw}"
  export RW_SEC_NONCE RW_BROKER_ROOT RW_CONTROL_PATH RW_EVIDENCE RW_RAW
}

# Rewrite exec_redact_file to also drop tailnet names and key material.
eval "$(declare -f exec_redact_file | sed '1s/exec_redact_file/exec_redact_file_base/')"
exec_redact_file() {
  local src="$1" dest="$2" remote_user
  exec_redact_file_base "$src" "$dest"
  remote_user="${RW_REMOTE_USER:-}"
  RW_REDACT_REMOTE_USER="$remote_user" perl -pi -e '
    my $ru = $ENV{RW_REDACT_REMOTE_USER} // "";
    s/[A-Za-z0-9.-]+\.ts\.net/private-name/g;
    if (length($ru) && $ru ne "user") {
      my $q = quotemeta($ru);
      s/$q/user/g;
    }
    s/ssh-(?:ed25519|rsa)\s+AAAA[A-Za-z0-9+\/=]+/ssh-key REDACTED/g;
    s/SHA256:[A-Za-z0-9+\/=]+/SHA256:REDACTED/g;
  ' "$dest"
}

sec_begin() {
  sec_prepare
  exec_begin "$@"
  RW_REMOTE_USER=$(ssh -G "$RW_SSH_TARGET" 2>/dev/null | awk '$1=="user"{print $2; exit}')
  export RW_REMOTE_USER
}

sec_canary_file() {
  local file
  file=$(mktemp "${TMPDIR:-/tmp}/rw-sec-token.XXXXXX")
  chmod 600 "$file"
  od -An -N24 -tx1 /dev/urandom | tr -d ' \n' >"$file"
  printf 'rwcanary\n' >>"$file"
  # One line, no trailing distinction that would miss a partial copy.
  # The value is the whole first line. Rewrite to a single token.
  local token
  token="rwcanary$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n' "$token" >"$file"
  chmod 600 "$file"
  printf '%s\n' "$file"
}

sec_canary_value() {
  local file="$1"
  awk 'NR==1{print; exit}' "$file"
}

# Search the remote write surface and process environment.
# Prints one line of counts. The canary travels on ssh stdin, not in argv.
sec_scan_remote() {
  local canary="$1"
  shift
  local scratch="${1:-}" broker="${2:-}"
  local payload
  payload=$(mktemp "${TMPDIR:-/tmp}/rw-sec-scan.XXXXXX")
  chmod 600 "$payload"
  CANARY="$canary" SCRATCH="$scratch" BROKER="$broker" LOCAL="${RW_LOCAL_ROOT:-}" SINCE="$(( $(date +%s) - 180 ))" python3 - "$payload" <<'PY'
import json, os, sys
path = sys.argv[1]
body = "CANARY=" + json.dumps(os.environ["CANARY"]) + "\n"
body += "SCRATCH=" + json.dumps(os.environ.get("SCRATCH", "")) + "\n"
body += "BROKER=" + json.dumps(os.environ.get("BROKER", "")) + "\n"
body += "LOCAL=" + json.dumps(os.environ.get("LOCAL", "")) + "\n"
body += "SINCE=" + json.dumps(int(os.environ.get("SINCE", "0"))) + "\n"
body += r'''
import os, stat, sys, time, subprocess
canary = CANARY.encode()
scratch = SCRATCH
broker = BROKER
local_root = LOCAL
since = SINCE
deadline = time.monotonic() + 180
counts = {
    "files": 0, "proc": 0,
    "hits_scratch": 0, "hits_broker": 0, "hits_tmp": 0,
    "hits_home": 0, "hits_proc": 0, "hits_other": 0,
    "complete": 1,
}
skip_dirs = {
    ".git", "node_modules", "Library", "Caches", ".cache", ".npm",
    ".cargo", "target", "venv", ".venv", "site-packages", ".tox",
}
home = os.path.expanduser("~")

def norm(path):
    if path == "/private/tmp" or path.startswith("/private/tmp/"):
        return "/tmp" + path[len("/private/tmp"):]
    if path == "/private/var/tmp" or path.startswith("/private/var/tmp/"):
        return "/var/tmp" + path[len("/private/var/tmp"):]
    return path

def klass(path):
    path = norm(path)
    scratch_n = norm(scratch) if scratch else ""
    broker_n = norm(broker) if broker else ""
    if scratch_n and (path == scratch_n or path.startswith(scratch_n + os.sep)):
        return "scratch"
    if broker_n and (path == broker_n or path.startswith(broker_n + os.sep)):
        return "broker"
    if path == "/tmp" or path.startswith("/tmp/") or path == "/var/tmp" or path.startswith("/var/tmp/"):
        return "tmp"
    if home and (path == home or path.startswith(home + os.sep)):
        return "home"
    return "other"

def under_provider(path):
    path = norm(path)
    root = norm(local_root) if local_root else ""
    if not root:
        return False
    return path == root or path.startswith(root + os.sep)

def add_hit(path):
    # The provider startup file is allowed to keep its own secret.
    if under_provider(path):
        return
    key = "hits_" + klass(path)
    counts[key] = counts.get(key, 0) + 1

def scan_file(path, fresh_only):
    if time.monotonic() > deadline:
        counts["complete"] = 0
        return
    try:
        st = os.lstat(path)
    except OSError:
        return
    if not stat.S_ISREG(st.st_mode):
        return
    if fresh_only and st.st_mtime < since:
        return
    if st.st_size > 2000000 or st.st_size == 0:
        return
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return
    counts["files"] += 1
    if canary in data:
        add_hit(path)

def walk(root, fresh_only):
    if not root or counts["complete"] == 0:
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs and not d.startswith(".Trash")]
        if time.monotonic() > deadline:
            counts["complete"] = 0
            return
        for name in filenames:
            scan_file(os.path.join(dirpath, name), fresh_only)
            if counts["complete"] == 0:
                return

# Scratch and broker are read in full. Elsewhere, only files touched during
# this session can contain a canary that did not exist before it started.
seen_roots = set()

def root_key(root):
    try:
        st = os.stat(root)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)

for root in (scratch, broker):
    if root and os.path.isdir(root):
        key = root_key(root)
        if key is not None:
            seen_roots.add(key)
        walk(root, False)
for root in ("/tmp", "/var/tmp", "/private/tmp", "/private/var/tmp", home):
    if not root or not os.path.isdir(root):
        continue
    key = root_key(root)
    if key is None or key in seen_roots:
        continue
    seen_roots.add(key)
    walk(root, True)

me = os.getpid()
if os.path.isdir("/proc"):
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        if int(name) == me:
            continue
        if time.monotonic() > deadline:
            counts["complete"] = 0
            break
        base = os.path.join("/proc", name)
        for leaf in ("environ", "cmdline"):
            p = os.path.join(base, leaf)
            try:
                with open(p, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            counts["proc"] += 1
            if canary in data:
                counts["hits_proc"] += 1
else:
    try:
        out = subprocess.check_output(["ps", "eww", "-ax"], stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        out = b""
    counts["proc"] += 1
    # Drop this scanner's own command line if it ever contains the value.
    for line in out.splitlines():
        if canary in line:
            counts["hits_proc"] += 1

sys.stdout.write(
    "scan files={files} proc={proc} hits_scratch={hits_scratch} hits_broker={hits_broker} hits_tmp={hits_tmp} hits_home={hits_home} hits_proc={hits_proc} hits_other={hits_other} complete={complete} scope=full-scratch-broker-plus-session-files\n".format(**counts)
)
'''
open(path, "w").write(body)
PY
  exec_ssh python3 - <"$payload"
  local rc=$?
  rm -f "$payload"
  return "$rc"
}

sec_scan_ok() {
  local line="$1" key val
  if [[ "$line" != scan\ * ]]; then
    fail "remote scan returned no count line"
    return 1
  fi
  note "$line"
  for key in hits_scratch hits_broker hits_tmp hits_home hits_proc hits_other; do
    val=$(printf '%s\n' "$line" | sed -n "s/.*${key}=\\([0-9][0-9]*\\).*/\\1/p")
    if [[ -z "$val" || "$val" -ne 0 ]]; then
      fail "canary found on the remote (${key}=${val:-missing})"
      return 1
    fi
  done
  val=$(printf '%s\n' "$line" | sed -n 's/.*complete=\([0-9]\).*/\1/p')
  if [[ "$val" != 1 ]]; then
    fail "remote scan did not finish"
    return 1
  fi
  val=$(printf '%s\n' "$line" | sed -n 's/.*files=\([0-9][0-9]*\).*/\1/p')
  if [[ -z "$val" || "$val" -eq 0 ]]; then
    fail "remote scan read no files"
    return 1
  fi
  pass "canary absent from remote files and process environment"
  return 0
}
