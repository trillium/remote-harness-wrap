#!/bin/bash
# C8. Classify Grok's shell route. The binary is dynamically linked and
# hardened, and its shell is the in-process static shell unless a session
# shows otherwise.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

if ! command -v grok >/dev/null 2>&1; then
  fail "grok is not on PATH"
  coverage_finish c8
fi
note "grok: $(grok --version 2>/dev/null | head -1)"
grok_real=$(python3 -c 'import os; print(os.path.realpath(os.path.expanduser("~/.local/bin/grok")))')
file_line=$(file -b "$grok_real")
note "file: ${file_line}"
flags=$(otool -hv "$grok_real" | awk 'NR==4 {print}')
note "mach_flags: ${flags}"
dylibs=$(otool -L "$grok_real" | awk 'NR>1' | wc -l | tr -d ' ')
note "dylib_count: ${dylibs}"
sign=$(codesign -dv "$grok_real" 2>&1 | awk -F= '/^CodeDirectory/{print} /^flags/{print}')
note "codesign: ${sign}"
if printf '%s\n' "$flags" | grep -F -q 'NOUNDEFS' && printf '%s\n' "$flags" | grep -F -q 'DYLDLINK'; then
  note "linkage: dynamic system libraries, no undefined symbols"
fi
if printf '%s\n' "$sign" | grep -F -q 'runtime'; then
  note "hardened_runtime: yes"
fi
dyld_out="${RW_RAW}/c8-dyld.txt"
DYLD_INSERT_LIBRARIES=/tmp/rw-missing-interpose.dylib grok --version >"$dyld_out" 2>&1
dyld_rc=$?
if [[ "$dyld_rc" -eq 0 ]]; then
  pass "a missing DYLD_INSERT_LIBRARIES value did not stop grok --version"
  note "dyld_interpose: ignored"
else
  note "dyld_interpose: process exited ${dyld_rc}"
fi

proj="${RW_LOCAL_ROOT}/proj"
remote_proj="${RW_REMOTE_ROOT}/proj"
mkdir -p "$proj"
exec_ssh "mkdir -p -- $(printf '%q' "$remote_proj") && printf 'rw-remote-only-marker\n' > $(printf '%q' "$remote_proj/remote-only-marker.txt")" \
  || fail "could not place the remote marker"
raw_log="${RW_RAW}/c8-argv.log"
: >"$raw_log"
out="${RW_RAW}/c8-grok.out"
err="${RW_RAW}/c8-grok.err"
prompt='Use the bash tool exactly once and then stop. The command is: hostname; echo RW_C8_OK; cat remote-only-marker.txt. Do not use any other tool.'
(
  cd "$proj" || exit 97
  GROK_SHELL="$RW_WRAP" \
    SHELL="$RW_WRAP" \
    RW_SSH_TARGET="$RW_SSH_TARGET" \
    RW_PATH_MAP="$RW_PATH_MAP" \
    RW_LOG="$raw_log" \
    RW_TRANSPORT=broker \
    RW_BROKER_ROOT="$RW_BROKER_ROOT" \
    RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    RW_CONTROL_PERSIST="$RW_CONTROL_PERSIST" \
    grok --always-approve --max-turns 2 --tools Bash --no-memory --disable-web-search \
      -p "$prompt"
) >"$out" 2>"$err" &
pid=$!
ticks=0
while kill -0 "$pid" 2>/dev/null && [[ "$ticks" -lt 180 ]]; do
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
note "grok_exit: ${rc}"
exec_reject_secrets "$out" || true
exec_reject_secrets "$err" || true
wrapper_used=0
if [[ -s "$raw_log" ]] && grep -F -q '[-c]' "$raw_log"; then
  wrapper_used=1
fi
remote_seen=0
if grep -F -q 'rw-remote-only-marker' "$out" || grep -F -q "$RW_REMOTE_HOSTNAME" "$out"; then
  remote_seen=1
fi
provider_seen=0
if grep -F -q "$RW_PROVIDER_HOSTNAME" "$out"; then
  provider_seen=1
fi
if [[ "$wrapper_used" -eq 1 && "$remote_seen" -eq 1 ]]; then
  pass "Grok bash ran through the shell wrapper on the remote"
  note "route: exec wrapper"
elif [[ "$provider_seen" -eq 1 && "$wrapper_used" -eq 0 ]]; then
  pass "Grok bash ran on the provider and did not call the shell wrapper"
  note "route: static local shell"
  note "reason: GROK_SHELL set to the wrapper path was not executed; the command printed the provider hostname"
else
  note "route: unclassified"
  note "wrapper_used: ${wrapper_used}"
  note "remote_seen: ${remote_seen}"
  note "provider_seen: ${provider_seen}"
  if [[ "$rc" -eq 124 ]]; then
    fail "grok did not finish"
  else
    fail "grok session did not show a local or remote shell result"
  fi
fi
note "RESULT: see passes"
coverage_finish c8
