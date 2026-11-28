#!/bin/bash
# E3. Password login is refused, and a connection to a public address is refused.
# The peer's own addresses are classified. Evidence stores classes, not addresses.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
sec_begin "$@"

ask=$(mktemp "${TMPDIR:-/tmp}/rw-e3-ask.XXXXXX")
cfg=$(mktemp "${TMPDIR:-/tmp}/rw-e3-cfg.XXXXXX")
chmod 700 "$ask" "$cfg"
printf '#!/bin/sh\nprintf "%%s\\n" "rw-e3-dummy"\n' >"$ask"
cat >"$cfg" <<EOF
Host *
  IdentitiesOnly yes
  IdentityFile /dev/null
  PasswordAuthentication yes
  PubkeyAuthentication no
  KbdInteractiveAuthentication no
  PreferredAuthentications password
  NumberOfPasswordPrompts 1
  StrictHostKeyChecking yes
  UserKnownHostsFile ${HOME}/.ssh/known_hosts
  GlobalKnownHostsFile /dev/null
  ControlMaster no
  ControlPath /tmp/rw-sec-e3-${RW_SEC_NONCE}-%C
  ForwardAgent no
  GSSAPIAuthentication no
  HostbasedAuthentication no
  BatchMode no
EOF
err=$(mktemp "${TMPDIR:-/tmp}/rw-e3-err.XXXXXX")
# rw-raw-ssh-rc-ok: login probe running `true`; the status is the login result (255 on refusal), not a remote command's status
SSH_AUTH_SOCK='' SSH_ASKPASS="$ask" SSH_ASKPASS_REQUIRE=force DISPLAY=dummy \
  ssh -F "$cfg" -v -o ConnectTimeout=8 -T "$RW_SSH_TARGET" 'printf SHOULD_NOT_RUN\n' \
  >"${RW_RAW}/e3-out.txt" 2>"$err"
rc=$?
session=no
method=refused
password_offered=no
if grep -F -q 'SHOULD_NOT_RUN' "${RW_RAW}/e3-out.txt"; then
  session=yes
fi
if grep -F -q 'using "none"' "$err"; then
  method=none
elif grep -F -q 'using "password"' "$err"; then
  method=password
elif grep -F -q 'using "publickey"' "$err"; then
  method=publickey
fi
if grep -E -q 'Authentications that can continue:.*password' "$err"; then
  password_offered=yes
fi
note "password_attempt session=${session} method=${method} password_offered=${password_offered} exit=${rc}"
if [[ "$session" == yes || "$method" == none || "$method" == password ]]; then
  fail "password or unauthenticated login opened a session"
else
  pass "password login did not open a session"
fi
rm -f "$err" "${RW_RAW}/e3-out.txt" "$ask" "$cfg"

# Public address: the wrapper must refuse before the command runs.
refuse_check() {
  local target="$1" started elapsed
  local out err
  out=$(mktemp "${TMPDIR:-/tmp}/rw-e3-pub.XXXXXX")
  err=$(mktemp "${TMPDIR:-/tmp}/rw-e3-pub.XXXXXX")
  started=$(date +%s)
  RW_SSH_TARGET="$target" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    "$RW_WRAP" -c 'printf SHOULD_NOT_RUN\n' >"$out" 2>"$err" &
  local pid=$!
  local ticks=0
  while kill -0 "$pid" 2>/dev/null && [[ "$ticks" -lt 5 ]]; do
    sleep 1
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "public target ${target} did not return within 5s"
  else
    wait "$pid"
    local wrc=$?
    elapsed=$(( $(date +%s) - started ))
    if grep -F -q 'SHOULD_NOT_RUN' "$out"; then
      fail "public target ${target} ran the command"
    elif grep -F -q 'not on the private network' "$err"; then
      pass "public target refused before a connection (${elapsed}s)"
    else
      fail "public target ${target} failed without the private-network refusal (exit ${wrc})"
    fi
  fi
  rm -f "$out" "$err"
}
refuse_check 1.1.1.1
refuse_check 203.0.113.5

# Positive control: the configured private target still runs a command.
ok=$(mktemp "${TMPDIR:-/tmp}/rw-e3-ok.XXXXXX")
exec_wrapper "$RW_LOCAL_ROOT/proj" 'printf E3_PRIVATE_OK\n' >"$ok" 2>"${RW_RAW}/e3-private.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F -q 'E3_PRIVATE_OK' "$ok"; then
  pass "private target still runs a command"
else
  fail "private target did not run a command (exit ${rc})"
fi
rm -f "$ok"

# Reachability of the peer's own addresses, by class only.
# The address list stays in a temp file and is never written to the evidence.
classes=$(exec_ssh python3 - <<'PY'
import os, re, subprocess, ipaddress
def classify(ip):
    a = ipaddress.ip_address(ip)
    if a.is_loopback or a.is_link_local:
        return None
    if a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10"):
        return "tailscale4"
    if a.version == 6 and a in ipaddress.ip_network("fd7a:115c:a1e0::/48"):
        return "tailscale6"
    if a.version == 4 and a in ipaddress.ip_network("10.0.0.0/8"):
        return "rfc1918"
    if a.version == 4 and a in ipaddress.ip_network("172.16.0.0/12"):
        return "rfc1918"
    if a.version == 4 and a in ipaddress.ip_network("192.168.0.0/16"):
        return "rfc1918"
    if a.is_global:
        return "public"
    return "other"
raw = ""
for cmd in (["ip", "-o", "addr"], ["ifconfig"]):
    try:
        raw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        break
    except (OSError, subprocess.CalledProcessError):
        continue
seen = []
for token in re.findall(r"[0-9a-fA-F:.]+", raw):
    try:
        addr = ipaddress.ip_address(token)
    except ValueError:
        continue
    if addr.is_multicast or addr.is_unspecified or addr.is_reserved:
        continue
    kind = classify(token)
    if kind and token not in seen:
        seen.append(token + " " + kind)
print("\n".join(seen))
PY
)
clsfile=$(mktemp "${TMPDIR:-/tmp}/rw-e3-cls.XXXXXX")
chmod 600 "$clsfile"
printf '%s\n' "$classes" >"$clsfile"
probe=$(python3 - "$clsfile" <<'PY'
import socket, sys
from concurrent.futures import ThreadPoolExecutor
rows = []
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line or " " not in line:
            continue
        ip, kind = line.split(" ", 1)
        rows.append((ip, kind))
# Keep at most four addresses per class.
kept = []
per = {}
for ip, kind in rows:
    per[kind] = per.get(kind, 0) + 1
    if per[kind] <= 4:
        kept.append((ip, kind))

def probe(item):
    ip, kind = item
    fam = socket.AF_INET6 if ":" in ip else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_STREAM)
    s.settimeout(1.5)
    state = "closed"
    try:
        s.connect((ip, 22))
        s.settimeout(1.0)
        try:
            b = s.recv(16)
            state = "open" if b.startswith(b"SSH-") else "open"
        except OSError:
            state = "open"
    except ConnectionRefusedError:
        state = "refused"
    except socket.timeout:
        state = "timeout"
    except OSError:
        state = "closed"
    finally:
        s.close()
    return kind, state

tally = {}
with ThreadPoolExecutor(max_workers=8) as pool:
    for kind, state in pool.map(probe, kept):
        key = kind + "_" + state
        tally[key] = tally.get(key, 0) + 1
print("peer", " ".join("%s=%s" % (k, tally[k]) for k in sorted(tally)))
PY
)
rm -f "$clsfile"
note "peer-interfaces ${probe}"
if printf '%s\n' "$probe" | grep -E -q 'public_open='; then
  if printf '%s\n' "$probe" | grep -E -q 'public_open=[1-9]'; then
    fail "a public address accepted a connection on port 22"
  else
    pass "no public address accepted a connection on port 22"
  fi
else
  pass "peer has no public address that accepted a connection"
fi
# A documentation public address from this provider must not complete a session.
pub_rc=0
python3 - <<'PY' || pub_rc=$?
import socket, sys
s = socket.socket()
s.settimeout(3)
try:
    s.connect(("1.1.1.1", 22))
except OSError:
    sys.exit(0)
finally:
    s.close()
sys.exit(1)
PY
if [[ "$pub_rc" -eq 0 ]]; then
  pass "connection to a public address did not open"
else
  fail "connection to a public address opened"
fi
exec_finish e3
