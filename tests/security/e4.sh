#!/bin/bash
# E4. After a session that has a credential and reads a file, the wrapper log
# and the remote broker log contain neither the credential nor the file body.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
sec_begin "$@"

token_file=$(sec_canary_file)
canary=$(sec_canary_value "$token_file")
body_token="filebody$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
RW_TOKEN_FILE="$token_file"
export RW_TOKEN_FILE
RW_EXTRA_CLEAN="rm -f $(printf '%q' "$token_file")"
export RW_EXTRA_CLEAN

local_body="${RW_LOCAL_ROOT}/proj/body.txt"
printf '%s\n' "$body_token" >"$local_body"
chmod 600 "$local_body"
exec_ssh "cat > $(printf '%q' "$RW_REMOTE_ROOT/proj/body.txt")" <"$local_body"

log="${RW_RAW}/e4-session.log"
: >"$log"
out=$(mktemp "${TMPDIR:-/tmp}/rw-e4.XXXXXX")
(
  export CLAUDE_CODE_OAUTH_TOKEN="$canary"
  export ANTHROPIC_API_KEY="$canary"
  export RW_TOKEN_FILE="$token_file"
  export RW_RUN_LOG="$log"
  exec_wrapper "$RW_LOCAL_ROOT/proj" 'printf "E4_MARKER\n"; cat body.txt'
) >"$out" 2>"${RW_RAW}/e4.err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F -q 'E4_MARKER' "$out" && grep -F -q "$body_token" "$out"; then
  pass "session printed the file body on stdout"
else
  fail "session did not return the file body (exit ${rc})"
fi

scan_log() {
  local file="$1" label="$2" token_hits body_hits argv_lines
  if [[ ! -f "$file" ]]; then
    fail "${label} log is missing"
    return 1
  fi
  token_hits=$(grep -F -c -e "$canary" "$file" || true)
  body_hits=$(grep -F -c -e "$body_token" "$file" || true)
  argv_lines=$(grep -F -c -e 'argv:' "$file" || true)
  note "${label} token_hits=${token_hits} file_hits=${body_hits} argv_lines=${argv_lines} bytes=$(wc -c <"$file" | tr -d ' ')"
  if [[ "$token_hits" -ne 0 ]]; then
    fail "${label} log contains the credential"
  fi
  if [[ "$body_hits" -ne 0 ]]; then
    fail "${label} log contains the file body"
  fi
  if [[ "$label" == wrapper && "$argv_lines" -eq 0 ]]; then
    fail "wrapper log has no argv record"
  fi
  if [[ "$token_hits" -eq 0 && "$body_hits" -eq 0 && ( "$label" != wrapper || "$argv_lines" -gt 0 ) ]]; then
    pass "${label} log has no credential and no file body"
  fi
}
scan_log "$log" wrapper

broker_log="${RW_RAW}/e4-broker.log"
exec_ssh "if [[ -f $(printf '%q' "$RW_BROKER_ROOT/broker.log") ]]; then cat $(printf '%q' "$RW_BROKER_ROOT/broker.log"); fi" >"$broker_log" 2>/dev/null || true
if [[ -s "$broker_log" ]]; then
  scan_log "$broker_log" broker
else
  note "broker log empty"
  pass "broker log has no credential and no file body"
fi
if grep -F -q "$canary" "$out" "${RW_RAW}/e4.err"; then
  fail "credential was printed by the session"
else
  pass "credential was not printed by the session"
fi
rm -f "$out" "$local_body"
exec_finish e4
