#!/bin/bash
# C4. Claude Code, one session, three questions:
#   persistent shell  - a `cd` in one Bash call is still in effect in the next,
#                       and both calls ran on the remote.
#   hooks             - a PreToolUse hook runs on the provider (local).
#   local tool server - an MCP stdio server starts and is called on the provider (local).
# RW_TOKEN_FILE is optional. Without it the session uses the login already on the provider.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v claude >/dev/null 2>&1; then
  fail "claude is not on PATH"
  coverage_finish c4
fi
note "claude: $(claude --version 2>/dev/null | head -1)"

token_file="${RW_TOKEN_FILE:-}"
if [[ -n "$token_file" && -s "$token_file" ]]; then
  note "credential: token file"
else
  token_file=""
  note "credential: existing provider login"
fi

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj/sub") && printf 'rw-remote-only-marker\n' > $(printf '%q' "$remote_proj/sub/remote-only-marker.txt")" \
  || fail "could not place the remote marker"

hook_out="${RW_RAW}/c4-hook.txt"
mcp_out="${RW_RAW}/c4-mcp.txt"
rm -f "$hook_out" "$mcp_out"
hook_script="${RW_RAW}/c4-hook.sh"
mcp_script="${RW_RAW}/c4-mcp.py"
cat >"$hook_script" <<EOF
#!/bin/bash
cat >/dev/null
printf '%s\n' "\$(hostname)" >> $(printf '%q' "$hook_out")
EOF
chmod +x "$hook_script"
cat >"$mcp_script" <<'PY'
import json, os, socket, sys
path = os.environ["RW_MCP_OUT"]
open(path, "a").write("mcp-started " + socket.gethostname() + "\n")
def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
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
            "serverInfo": {"name": "rw-probe", "version": "0"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{
            "name": "whereami",
            "description": "Returns the host name of the machine this tool server runs on.",
            "inputSchema": {"type": "object", "properties": {}}}]}})
    elif method == "tools/call":
        open(path, "a").write("mcp-called " + socket.gethostname() + "\n")
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": "RW_C4_MCP_HOST=" + socket.gethostname()}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
PY

settings="${RW_RAW}/c4-settings.json"
mcp_config="${RW_RAW}/c4-mcp.json"
python3 - "$settings" "$mcp_config" "$hook_script" "$mcp_script" "$mcp_out" <<'PY'
import json, sys
settings, mcp_config, hook, mcp, mcp_out = sys.argv[1:]
json.dump({"sandbox": {"enabled": False},
           "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": hook}]}],
                     "PreToolUse": [{"matcher": "Bash",
                                      "hooks": [{"type": "command", "command": hook}]}]}},
          open(settings, "w"))
json.dump({"mcpServers": {"rw-probe": {"command": "python3", "args": [mcp],
                                        "env": {"RW_MCP_OUT": mcp_out}}}},
          open(mcp_config, "w"))
PY

prompt='Do these in order, one tool call each, and then stop. 1) Bash: cd sub && hostname. 2) Bash: pwd && hostname && cat remote-only-marker.txt. 3) the whereami tool from the rw-probe MCP server. After each call print its output verbatim. Do not read, write, edit, search, or print the environment, tokens, or home directory.'
out="${RW_RAW}/c4-claude.out"
err="${RW_RAW}/c4-claude.err"
raw_log="${RW_RAW}/c4-argv.log"
: >"$raw_log"
(
  cd "$proj" || exit 97
  if [[ -n "$token_file" ]]; then
    CLAUDE_CODE_OAUTH_TOKEN=$(<"$token_file")
    export CLAUDE_CODE_OAUTH_TOKEN
  fi
  CLAUDE_CODE_SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    claude -p \
      --permission-mode bypassPermissions \
      --dangerously-skip-permissions \
      --allowedTools "Bash,mcp__rw-probe__whereami" \
      --disallowedTools "Edit,Write,NotebookEdit,Read,Grep,Glob" \
      --mcp-config "$mcp_config" \
      --strict-mcp-config \
      --effort low \
      --settings "$settings" \
      "$prompt"
) >"$out" 2>"$err" &
pid=$!
ticks=0
while kill -0 "$pid" 2>/dev/null && [[ "$ticks" -lt 300 ]]; do
  sleep 1
  ticks=$((ticks + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rc=124
else
  wait "$pid"
  rc=$?
fi
note "claude_exit: ${rc}"
exec_reject_secrets "$out"
exec_reject_secrets "$err"
refused=0
if grep -E -i -q "failed to authenticate|access token is invalid|usage limit|rate limit|quota exceeded|hit your limit|try again at|not logged in|can't use your claude subscription" "$out" "$err"; then
  refused=1
  note "session: refused by the account before any tool call"
fi
if [[ "$refused" -eq 1 ]]; then
  # Hooks and tool servers start before the first model turn, so locality is still observable.
  if [[ -s "$hook_out" && "$(sort -u "$hook_out")" == "$RW_PROVIDER_HOSTNAME" ]]; then
    pass "SessionStart hook ran on the provider"
    note "hook: local"
  else
    note "hook: not-observed"
  fi
  if grep -q '^mcp-started' "$mcp_out" 2>/dev/null \
    && [[ "$(grep '^mcp-started' "$mcp_out" | head -1 | awk '{print $2}')" == "$RW_PROVIDER_HOSTNAME" ]]; then
    pass "MCP server process started on the provider"
    note "mcp: local (started; no tool call issued)"
  else
    note "mcp: not-observed"
  fi
  note "persistent shell: not-observed"
  note "mcp tool call: not-observed"
  note "The account refused the session. No other account was tried."
  note "RESULT: partial account-refused"
  coverage_finish c4
fi

# Persistent shell: call 2 ran in sub/ without a cd, on the remote.
if grep -F -q 'rw-remote-only-marker' "$out"; then
  pass "second Bash call saw the remote-only file in sub/ without its own cd"
  note "persistent_cwd: yes"
else
  fail "second Bash call did not see the remote-only file in sub/"
  note "persistent_cwd: no"
fi
if [[ -n "$RW_REMOTE_HOSTNAME" ]] && grep -F -q "$RW_REMOTE_HOSTNAME" "$out" \
  && ! grep -F -q "$RW_PROVIDER_HOSTNAME" "$out"; then
  pass "both Bash calls printed the remote hostname and not the provider hostname"
  note "shell_host: remote"
else
  fail "Bash output did not show the remote hostname alone"
  note "shell_host: unclear"
fi
if grep -E -q '/sub([[:space:]]|$)' "$out"; then
  pass "pwd shows the mapped sub directory"
else
  fail "pwd did not show the sub directory"
fi

# Hook: ran, and ran on the provider.
if [[ -s "$hook_out" ]]; then
  hook_n=$(wc -l <"$hook_out" | tr -d ' ')
  if [[ "$(sort -u "$hook_out")" == "$RW_PROVIDER_HOSTNAME" ]]; then
    pass "PreToolUse hook ran on the provider for each Bash call"
    note "hook: local (${hook_n} calls)"
  else
    fail "PreToolUse hook host was not the provider"
    note "hook: other"
  fi
else
  fail "PreToolUse hook did not run"
  note "hook: not-run"
fi

# Local tool server: started and called on the provider.
if grep -q '^mcp-started' "$mcp_out" 2>/dev/null && grep -q '^mcp-called' "$mcp_out" 2>/dev/null; then
  mcp_host=$(grep '^mcp-called' "$mcp_out" | head -1 | awk '{print $2}')
  if [[ "$mcp_host" == "$RW_PROVIDER_HOSTNAME" ]]; then
    pass "MCP server started and answered a tool call on the provider"
    note "mcp: local"
  else
    fail "MCP server ran on a host other than the provider"
    note "mcp: other"
  fi
else
  fail "MCP server did not start or was not called"
  note "mcp: not-called"
fi
if [[ "$rc" -eq 0 ]]; then
  pass "claude -p exited 0"
else
  fail "claude -p exited ${rc}"
fi
note "RESULT: see passes"
coverage_finish c4
