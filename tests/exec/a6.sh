#!/bin/bash
# A6. A background process survives after the command returns.
# One ssh per command closes the channel and the background process dies.
# The broker keeps its own session, so a later command can reach the server.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

a6_cleanup() {
  local pid n
  n=${#A6_PIDS[@]}
  [[ "$n" -gt 0 ]] || return 0
  for pid in "${A6_PIDS[@]}"; do
    [[ -n "$pid" ]] || continue
    exec_ssh "kill -KILL -${pid} 2>/dev/null || kill -KILL ${pid} 2>/dev/null || true" >/dev/null 2>&1 || true
  done
}
A6_PIDS=()
export RW_EXTRA_CLEAN="a6_cleanup"

start_server() {
  local body="$1"
  case "$body" in
    *[!A-Za-z0-9-]*) printf 'bad server token\n' >&2; return 1 ;;
  esac
  # stdin is /dev/null so a one-ssh session can close. The process is still
  # in that session, which is what the oneshot case is there to expose.
  cat <<EOF
python3 -c '
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()
open("server.port", "w").write(str(port))
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"${body}"
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, fmt, *args):
        return
HTTPServer(("127.0.0.1", port), H).serve_forever()
' </dev/null >server.log 2>&1 &
echo \$! > server.pid
printf 'LAUNCHED\n'
EOF
}

reach_script() {
  cat <<'EOF'
port=$(tr -cd '0-9' < server.port)
python3 -c 'import sys, urllib.request
port = sys.argv[1]
print(urllib.request.urlopen("http://127.0.0.1:%s/" % port, timeout=3).read().decode())' "$port"
EOF
}

run_pair() {
  local transport="$1" body="$2" work
  work=$(mktemp -d "${TMPDIR:-/tmp}/rw-a6.XXXXXX")
  exec_ssh "rm -f $(printf '%q' "$RW_REMOTE_ROOT/proj/server.port") $(printf '%q' "$RW_REMOTE_ROOT/proj/server.pid")" >/dev/null 2>&1 || true
  RW_TRANSPORT="$transport" exec_wrapper "$RW_LOCAL_ROOT/proj" "$(start_server "$body")" >"${work}/start.out" 2>"${work}/start.err" &
  local spid=$!
  local ticks=0
  while kill -0 "$spid" 2>/dev/null && [[ "$ticks" -lt 40 ]]; do
    sleep 0.25
    ticks=$((ticks + 1))
  done
  local src=0
  if kill -0 "$spid" 2>/dev/null; then
    kill -TERM "$spid" 2>/dev/null || true
    wait "$spid" 2>/dev/null || true
    src=124
    printf 'start did not return\n' >>"${work}/start.err"
  else
    wait "$spid"
    src=$?
  fi
  local rrc=1 got=""
  ticks=0
  while [[ "$ticks" -lt 8 ]]; do
    RW_TRANSPORT="$transport" exec_wrapper "$RW_LOCAL_ROOT/proj" "$(reach_script)" >"${work}/reach.out" 2>"${work}/reach.err"
    rrc=$?
    got=$(tr -d '\r' <"${work}/reach.out" 2>/dev/null || true)
    got=${got%$'\n'}
    [[ "$got" == "$body" ]] && break
    sleep 0.4
    ticks=$((ticks + 1))
  done
  local pid
  pid=$(exec_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/proj/server.pid") 2>/dev/null" || true)
  pid=$(printf '%s' "$pid" | tr -cd '0-9')
  if [[ -n "$pid" ]]; then
    A6_PIDS+=("$pid")
  fi
  printf '%s\n' "$src" >"${work}/start.rc"
  printf '%s\n' "$rrc" >"${work}/reach.rc"
  printf '%s\n' "$got" >"${work}/got"
  A6_WORK="$work"
}

note "oneshot: one ssh per command"
run_pair oneshot "rw-a6-oneshot"
oneshot_work="$A6_WORK"
oneshot_got=$(cat "${oneshot_work}/got")
oneshot_rrc=$(cat "${oneshot_work}/reach.rc")
if [[ "$oneshot_got" == "rw-a6-oneshot" ]]; then
  note "ONESHOT: background server still reachable after the command returned"
else
  note "ONESHOT: background server was not reachable (reach rc ${oneshot_rrc})"
  pass "oneshot does not keep a background server"
fi
rm -rf "$oneshot_work"
a6_cleanup
A6_PIDS=()

note "broker: detached remote session"
run_pair broker "rw-a6-broker"
broker_work="$A6_WORK"
broker_got=$(cat "${broker_work}/got")
broker_src=$(cat "${broker_work}/start.rc")
if [[ "$broker_src" -eq 0 && "$broker_got" == "rw-a6-broker" ]]; then
  pass "later command reached the background server"
else
  fail "broker server not reachable (start rc ${broker_src}, body [${broker_got}])"
  head -20 "${broker_work}/start.err" "${broker_work}/reach.err" | tee -a "$NOTES" || true
fi
rm -rf "$broker_work"
a6_cleanup
A6_PIDS=()
exec_finish a6
