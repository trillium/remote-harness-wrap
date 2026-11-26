#!/bin/bash
# C1. Stock Claude Code, second account, shell wrapper, remote hostname and a
# remote-only marker. C4 hooks and the local MCP probe start in the same session.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is not on PATH"
  coverage_finish c1
fi
note "claude: $(claude --version 2>/dev/null | head -1)"

token_file="${RW_TOKEN_FILE:-}"
if [[ -z "$token_file" || ! -f "$token_file" || ! -s "$token_file" ]]; then
  fail "RW_TOKEN_FILE is missing"
  coverage_finish c1
fi
note "token file: present"
note "account: second"

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
printf 'local-only-marker\n' >"$proj/local-only-marker.txt"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj") && printf 'rw-remote-only-marker\n' > $(printf '%q' "$remote_proj/remote-only-marker.txt")" \
  || fail "could not place the remote marker"
if [[ -e "$proj/remote-only-marker.txt" ]]; then
  fail "remote marker was visible on the provider before the session"
else
  pass "remote marker is absent on the provider"
fi

hook_out="${RW_RAW}/c1-hook.txt"
mcp_out="${RW_RAW}/c1-mcp.txt"
rm -f "$hook_out" "$mcp_out"
hook_script="${RW_RAW}/c1-hook.sh"
mcp_script="${RW_RAW}/c1-mcp.py"
cat >"$hook_script" <<EOF
#!/bin/bash
hostname > $(printf '%q' "$hook_out")
printf 'hook-ran\n' >> $(printf '%q' "$hook_out")
EOF
chmod +x "$hook_script"
cat >"$mcp_script" <<'PY'
import json, os, sys
path = os.environ["RW_MCP_OUT"]
open(path, "w").write("mcp-started\n")
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        params = msg.get("params") or {}
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": params.get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "rw-probe", "version": "0"},
        }})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": []}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
PY
settings="${RW_RAW}/c1-settings.json"
python3 - "$settings" "$hook_script" "$mcp_script" "$mcp_out" <<'PY'
import json, sys
settings, hook, mcp, mcp_out = sys.argv[1:]
doc = {
    "sandbox": {"enabled": False},
    "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": hook}]}]},
    "mcpServers": {
        "rw-probe": {
            "command": "python3",
            "args": [mcp],
            "env": {"RW_MCP_OUT": mcp_out},
        }
    },
}
open(settings, "w").write(json.dumps(doc))
PY

raw_log="${RW_RAW}/c1-argv.log"
: >"$raw_log"
prompt='Use the Bash tool exactly once and then stop. The command is: hostname; echo RW_C1_OK; cat remote-only-marker.txt. Do not read, write, edit, search, or print the environment, tokens, or home directory.'
claude_out="${RW_RAW}/c1-claude.out"
claude_err="${RW_RAW}/c1-claude.err"
(
  cd "$proj" || exit 97
  CLAUDE_CODE_OAUTH_TOKEN=$(<"$token_file") \
    CLAUDE_CODE_SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    RW_MCP_OUT="$mcp_out" \
    claude -p \
      --permission-mode bypassPermissions \
      --dangerously-skip-permissions \
      --allowedTools Bash \
      --disallowedTools "Edit,Write,NotebookEdit,Read,Grep,Glob" \
      --effort low \
      --settings "$settings" \
      "$prompt"
) >"$claude_out" 2>"$claude_err" &
claude_pid=$!
ticks=0
while kill -0 "$claude_pid" 2>/dev/null && [[ "$ticks" -lt 240 ]]; do
  sleep 1
  ticks=$((ticks + 1))
done
if kill -0 "$claude_pid" 2>/dev/null; then
  kill -TERM "$claude_pid" 2>/dev/null || true
  wait "$claude_pid" 2>/dev/null || true
  claude_rc=124
else
  wait "$claude_pid"
  claude_rc=$?
fi
note "claude_exit: ${claude_rc}"
exec_reject_secrets "$raw_log"
exec_reject_secrets "$claude_out"
exec_reject_secrets "$claude_err"

auth_refused=0
if grep -E -i -q 'failed to authenticate|access token is invalid' "$claude_out" "$claude_err"; then
  auth_refused=1
  note "auth: 401 invalid"
elif grep -E -i -q 'usage limit|rate limit|quota exceeded|hit your limit|try again at' "$claude_out" "$claude_err"; then
  auth_refused=1
  note "auth: limit"
fi

if [[ "$auth_refused" -eq 1 ]]; then
  note "shell: not-observed"
  note "hosts_differ: not-observed"
  note "marker: not-observed"
  note "The named account refused the session. No further account was tried."
else
  # The argv log holds the prompt, so only the session transcript counts.
  if grep -F -q 'RW_C1_OK' "$claude_out" || grep -F -q 'rw-remote-only-marker' "$claude_out"; then
    pass "real session ran the marker command"
  else
    fail "real session did not show the marker command"
  fi
  if grep -F -q 'rw-remote-only-marker' "$claude_out"; then
    pass "session observed the remote-only marker"
  else
    fail "session did not observe the remote-only marker"
  fi
  seen_remote=0
  if grep -F -q "$RW_REMOTE_HOSTNAME" "$claude_out"; then
    seen_remote=1
  fi
  seen_provider=0
  if grep -F -q "$RW_PROVIDER_HOSTNAME" "$claude_out"; then
    seen_provider=1
  fi
  if [[ "$seen_remote" -eq 1 && "$seen_provider" -eq 0 ]]; then
    pass "session printed the remote hostname and not the provider hostname"
    note "hosts_differ: yes"
  elif [[ "$seen_remote" -eq 1 ]]; then
    note "hosts_differ: remote hostname present"
    pass "session printed the remote hostname"
  else
    fail "session did not print the remote hostname"
    note "hosts_differ: no"
  fi
  if [[ "$claude_rc" -eq 0 ]]; then
    pass "claude -p exited 0"
  else
    fail "claude -p exited ${claude_rc}"
  fi
fi
if [[ -e "$proj/remote-only-marker.txt" ]]; then
  fail "remote marker appeared on the provider"
else
  pass "remote marker stayed off the provider"
fi

if [[ -f "$hook_out" ]] && grep -F -q 'hook-ran' "$hook_out"; then
  hook_host=$(head -1 "$hook_out" | tr -d '[:space:]')
  if [[ "$hook_host" == "$RW_PROVIDER_HOSTNAME" ]]; then
    pass "SessionStart hook ran on the provider"
    note "hook: local"
  else
    fail "SessionStart hook hostname was not the provider"
    note "hook: not-provider"
  fi
else
  fail "SessionStart hook did not run"
  note "hook: missing"
fi
if [[ -f "$mcp_out" ]] && grep -F -q 'mcp-started' "$mcp_out"; then
  pass "MCP server process started on the provider"
  note "mcp: local"
elif [[ "$auth_refused" -eq 1 ]]; then
  note "mcp: not-observed"
else
  note "mcp: not-started"
  fail "MCP server did not start"
fi
if [[ "$auth_refused" -eq 1 ]]; then
  note "RESULT: partial account-refused"
else
  note "RESULT: see passes"
fi
coverage_finish c1
