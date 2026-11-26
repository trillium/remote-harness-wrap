#!/bin/bash
# A1. A real harness session accepts this wrapper as its shell.
# The credential file path is RW_TOKEN_FILE. Its contents are never printed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

if [[ "$RW_SSH_TARGET" != "localhost" && "$RW_SSH_TARGET" != "127.0.0.1" && "${RW_FORCE_A1:-}" != 1 ]]; then
  note "RESULT: skipped on this target; one real session is enough"
  exec_finish a1
fi

if ! command -v claude >/dev/null 2>&1; then
  note "RESULT: partial claude-missing"
  fail "claude is not on PATH"
  exec_finish a1
fi
note "claude: $(claude --version 2>/dev/null | head -1)"

token_file="${RW_TOKEN_FILE:-}"
if [[ -z "$token_file" || ! -f "$token_file" || ! -s "$token_file" ]]; then
  note "RESULT: partial token-file-unavailable"
  fail "RW_TOKEN_FILE is missing"
  exec_finish a1
fi
note "token file: present"

proj="${RW_LOCAL_ROOT}/a1proj"
mkdir -p "$proj"
printf 'A trivial project for a shell check.\n' >"$proj/README.md"
exec_ssh "mkdir -p -- $(printf '%q' "$RW_REMOTE_ROOT/a1proj")" >/dev/null 2>&1 || true

raw_log="${RW_RAW}/a1-argv.log"
: >"$raw_log"
settings=$(mktemp "${TMPDIR:-/tmp}/rw-a1-settings.XXXXXX")
printf '%s\n' '{"sandbox":{"enabled":false}}' >"$settings"
prompt='Use the Bash tool exactly once and then stop. The command is: echo RW_A1_OK. Do not read files. Do not write or edit files. Do not print the environment, tokens, or home directory.'

claude_out="${RW_RAW}/a1-claude.out"
claude_err="${RW_RAW}/a1-claude.err"
set -m
(
  cd "$proj" || exit 97
  CLAUDE_CODE_OAUTH_TOKEN=$(<"$token_file") \
    CLAUDE_CODE_SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
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
set +m
ticks=0
while kill -0 "$claude_pid" 2>/dev/null && [[ "$ticks" -lt 240 ]]; do
  sleep 1
  ticks=$((ticks + 1))
done
if kill -0 "$claude_pid" 2>/dev/null; then
  kill -TERM -"$claude_pid" 2>/dev/null || kill -TERM "$claude_pid" 2>/dev/null || true
  wait "$claude_pid" 2>/dev/null || true
  claude_rc=124
  note "claude did not finish within 240s"
else
  wait "$claude_pid"
  claude_rc=$?
fi
rm -f "$settings"
note "claude_exit: ${claude_rc}"

exec_reject_secrets "$raw_log"
exec_reject_secrets "$claude_out"
exec_reject_secrets "$claude_err"

if grep -E -i -q 'usage limit|rate limit|quota exceeded|hit your limit|try again at' "$claude_out" "$claude_err"; then
  note "RESULT: partial account-exhausted"
  note "The named account refused the session. No further account was tried."
  exec_finish a1
fi

if grep -F -q '[-c]' "$raw_log"; then
  pass "wrapper argv log contains -c"
else
  fail "wrapper argv log has no -c invocation"
fi
if grep -F -q '[-c] [-l]' "$raw_log" || grep -F -q '[-lc]' "$raw_log" || grep -F -q '[-cl]' "$raw_log"; then
  pass "wrapper argv log shows the harness login form"
else
  note "argv did not include -l; the harness called -c only"
fi
if grep -F -q 'RW_A1_OK' "$raw_log" || grep -F -q 'RW_A1_OK' "$claude_out"; then
  pass "real session ran the marker command"
else
  fail "real session did not show the marker command"
  head -30 "$claude_err" | tee -a "$NOTES" || true
fi
if [[ "$claude_rc" -eq 0 ]]; then
  pass "claude -p exited 0"
else
  fail "claude -p exited ${claude_rc}"
fi
if exec_ssh "tar -cf - $(printf '%q' "$RW_REMOTE_ROOT") $(printf '%q' "${RW_BROKER_ROOT:-/tmp/rw-exec-broker}")" 2>/dev/null | grep -F -q -f "$token_file"; then
  exec_ssh "rm -rf -- $(printf '%q' "$RW_REMOTE_ROOT") $(printf '%q' "${RW_BROKER_ROOT:-/tmp/rw-exec-broker}")" >/dev/null 2>&1 || true
  fail "credential material reached the remote scratch"
else
  pass "credential material was not in the remote scratch"
fi
note "RESULT: see passes"
# Keep a redacted argv transcript beside the assertion log.
# The raw log stays outside the repo. The committed copy records the argv
# shape and the marker, and drops the snapshot body.
redacted=$(mktemp "${TMPDIR:-/tmp}/rw-a1-redacted.XXXXXX")
exec_redact_file "$raw_log" "$redacted"
exec_reject_secrets "$redacted"
perl -e '
  my $in = 0;
  my $argv = "";
  sub flush {
    return unless $in;
    my $flags = "";
    $flags .= "[-c] " if $argv =~ /\[-c\]/;
    $flags .= "[-l] " if $argv =~ /\[-l\]/;
    $flags .= "[-lc] " if $argv =~ /\[-lc\]/;
    my $marker = ($argv =~ /RW_A1_OK/) ? "RW_A1_OK" : "no";
    my $sent = ($argv =~ /pwd -P >\|/) ? "yes" : "no";
    printf "argv: %sbytes=%d marker=%s sentinel=%s\n", $flags, length($argv), $marker, $sent;
    $in = 0;
    $argv = "";
  }
  while (<>) {
    if (/^-----/) { flush(); print; next; }
    if (/^argv: /) { flush(); $in = 1; $argv = $_; next; }
    if ($in) {
      if (/^(?:local_cwd|target|transport|map|remote_cwd|remote_rc|broker|copied|omitted|source|sentinel)\b/) {
        flush();
        print;
        next;
      }
      $argv .= $_;
      next;
    }
    print if /^(?:local_cwd|target|transport|map|remote_cwd|remote_rc|broker|copied|omitted|source|sentinel)\b/;
  }
  flush();
' "$redacted" >"${RW_EVIDENCE}/$(exec_label)-a1-argv.log"
rm -f "$redacted"
exec_reject_secrets "${RW_EVIDENCE}/$(exec_label)-a1-argv.log"
exec_finish a1
