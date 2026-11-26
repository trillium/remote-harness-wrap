#!/bin/bash
# E1. A harness credential in the provider environment is not copied to the
# remote filesystem or to a remote process environment.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
sec_begin "$@"

token_file=$(sec_canary_file)
canary=$(sec_canary_value "$token_file")
RW_TOKEN_FILE="$token_file"
export RW_TOKEN_FILE
RW_EXTRA_CLEAN="rm -f $(printf '%q' "$token_file")"
export RW_EXTRA_CLEAN

out=$(mktemp "${TMPDIR:-/tmp}/rw-e1.XXXXXX")
err=$(mktemp "${TMPDIR:-/tmp}/rw-e1.XXXXXX")
script='printf "E1_MARKER\n"
for n in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN AWS_SECRET_ACCESS_KEY; do
  if [ -n "${!n+x}" ]; then
    v="${!n-}"
    set -- $(printf "%s" "$v" | cksum)
    printf "set %s len=%s sum=%s\n" "$n" "${#v}" "$1"
  else
    printf "unset %s\n" "$n"
  fi
done'
canary_sum=$(printf '%s' "$canary" | cksum | awk '{print $1}')

(
  export CLAUDE_CODE_OAUTH_TOKEN="$canary"
  export ANTHROPIC_API_KEY="$canary"
  export OPENAI_API_KEY="$canary"
  export GH_TOKEN="$canary"
  export GITHUB_TOKEN="$canary"
  export AWS_SECRET_ACCESS_KEY="$canary"
  export RW_TOKEN_FILE="$token_file"
  exec_wrapper "$RW_LOCAL_ROOT/proj" "$script"
) >"$out" 2>"$err"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -F -q 'E1_MARKER' "$out"; then
  pass "session command ran on the remote"
else
  fail "session command did not run (exit ${rc})"
  cat "$err" | tee -a "$NOTES" || true
fi
leaked=0
for name in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GH_TOKEN GITHUB_TOKEN AWS_SECRET_ACCESS_KEY; do
  if grep -F -q "set ${name} " "$out"; then
    sum=$(sed -n "s/^set ${name} len=[0-9]* sum=\\([0-9]*\\).*/\\1/p" "$out" | head -1)
    len=$(sed -n "s/^set ${name} len=\\([0-9]*\\) sum=.*/\\1/p" "$out" | head -1)
    if [[ "$sum" == "$canary_sum" ]]; then
      fail "provider variable ${name} carried the credential"
      leaked=1
    else
      note "${name} present_on_remote len=${len} value_is_credential=no"
    fi
  fi
done
if [[ "$leaked" -eq 0 ]]; then
  pass "credential value was not in the remote command environment"
fi
if grep -F -q "$canary" "$out" "$err"; then
  fail "canary value was printed by the remote command"
else
  pass "canary value was not printed"
fi

scan=$(sec_scan_remote "$canary" "$RW_REMOTE_ROOT" "$RW_BROKER_ROOT" | tail -n 1)
sec_scan_ok "$scan" || true
rm -f "$out" "$err"
exec_finish e1
