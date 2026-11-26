#!/bin/bash
# A3. The harness working directory follows cd across calls.
# The value the harness sees is the mapped provider path.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
exec_begin "$@"

sent="${RW_LOCAL_ROOT}/proj/sentinel-a3"
sent2="${RW_LOCAL_ROOT}/proj/sentinel-a3b"
rm -f "$sent" "$sent2"
script="mkdir -p sub && cd sub && pwd -P >| ${sent}"
exec_wrapper "$RW_LOCAL_ROOT/proj" "$script" >"${RW_RAW}/a3-out.txt" 2>"${RW_RAW}/a3-err.txt"
rc=$?
[[ "$rc" -eq 0 ]] && pass "cd call exit 0" || fail "cd call exit ${rc}"

want="${RW_LOCAL_ROOT}/proj/sub"
got=""
[[ -f "$sent" ]] && got=$(tr -d '\r' <"$sent")
got=${got%$'\n'}
if [[ "$got" == "$want" ]]; then
  pass "sentinel after cd is the mapped provider path"
else
  fail "sentinel [${got}] want [${want}]"
fi

mkdir -p "$want"
out2=$(mktemp "${TMPDIR:-/tmp}/rw-a3.XXXXXX")
script2="pwd -P >| ${sent2}; pwd"
exec_wrapper "$want" "$script2" >"$out2" 2>"${RW_RAW}/a3-err2.txt"
rc2=$?
[[ "$rc2" -eq 0 ]] && pass "second call exit 0" || fail "second call exit ${rc2}"
shown=$(tr -d '\r' <"$out2")
shown=${shown%$'\n'}
if [[ "$shown" == "$want" ]]; then
  pass "next pwd shows the mapped provider path"
else
  fail "next pwd [${shown}] want [${want}]"
fi
got2=""
[[ -f "$sent2" ]] && got2=$(tr -d '\r' <"$sent2")
got2=${got2%$'\n'}
if [[ "$got2" == "$want" ]]; then
  pass "second sentinel is the mapped provider path"
else
  fail "second sentinel [${got2}] want [${want}]"
fi
rm -f "$out2"
exec_finish a3
