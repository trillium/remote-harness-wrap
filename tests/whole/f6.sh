#!/bin/bash
# F6. Two wrapped sessions run at the same time against two different remotes.
# Each session has its own path map, broker directory and ssh control socket.
# Each remote holds a marker only that remote has. Neither session may see the
# other's marker, host name or created file, and neither remote may hold the
# other's files afterward.
#
#   tests/whole/f6.sh --target-a <ssh-host> --target-b <ssh-host>
#
# The second session starts 6 seconds after the first because OpenCode locks its local database when two start together; the commands run 20 seconds so the sessions overlap.
# The harness is OpenCode on its free model. It is the harness that could run
# at the time of the proof. It runs twice, once per remote.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WRAP="${RW_WRAP:-$ROOT/src/rw-bash}"
EVID="${RW_EVIDENCE:-$ROOT/evidence/whole}"
RAW="${RW_RAW:-${TMPDIR:-/tmp}/rw-f6-raw}"
TARGET_A=""
TARGET_B=""
HARNESS=opencode
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-a) TARGET_A="$2"; shift 2 ;;
    --target-b) TARGET_B="$2"; shift 2 ;;
    --harness) HARNESS="$2"; shift 2 ;;
    --evidence) EVID="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$RAW" "$EVID"
LOG=$(mktemp "${TMPDIR:-/tmp}/rw-f6-notes.XXXXXX")
PASSES=0
FAILS=0
note() { printf '%s\n' "$*" | tee -a "$LOG"; }
pass() { PASSES=$((PASSES + 1)); note "PASS: $*"; }
fail() { FAILS=$((FAILS + 1)); note "FAIL: $*"; }

# shellcheck source=../lib/ssh-inband.sh
. "$ROOT/tests/lib/ssh-inband.sh"

rssh() { # rssh <target> <control> <command...>
  local t="$1" c="$2"
  shift 2
  rw_ssh_inband ssh -o ControlMaster=auto -o ControlPersist=10m -o "ControlPath=$c" \
    -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR -T "$t" -- "$@"
}

[[ -n "$TARGET_A" && -n "$TARGET_B" && "$TARGET_A" != "$TARGET_B" ]] || {
  fail "two different ssh targets are required"
  exit 1
}
case "$HARNESS" in
  opencode)
    command -v opencode >/dev/null 2>&1 || { fail "opencode is not on PATH"; exit 1; }
    note "harness: opencode $(opencode --version 2>/dev/null | head -1) (free model, two concurrent sessions)" ;;
  claude)
    command -v claude >/dev/null 2>&1 || { fail "claude is not on PATH"; exit 1; }
    note "harness: claude $(claude --version 2>/dev/null | head -1) (two concurrent sessions)"
    if [[ -n "${RW_TOKEN_FILE:-}" && -s "$RW_TOKEN_FILE" ]]; then
      note "credential: token file"
    else
      note "credential: existing provider login"
    fi ;;
  *) fail "unknown harness: $HARNESS"; exit 1 ;;
esac

NONCE=$(date +%s)$RANDOM
# bash 3.2 has no associative arrays: variables are named by side, e.g. TGT_a.
get() { eval "printf '%s' \"\${$1_$2:-}\""; }
set_() { eval "$1_$2=\$3"; }
TGT_a="$TARGET_A"; TGT_b="$TARGET_B"
for s in a b; do
  set_ LOCAL $s "$(mktemp -d "/tmp/rw-f6-${s}-local.XXXXXX")"
  set_ REMOTE $s "/tmp/rw-f6-${s}-${NONCE}"
  set_ CTRL $s "/tmp/rw-f6-${s}-%C"
  set_ BROKER $s "/tmp/rw-f6-${s}-broker-${NONCE}"
  mkdir -p "$(get LOCAL $s)/proj"
  set_ HOST $s "$(rssh "$(get TGT $s)" "$(get CTRL $s)" hostname | tr -d '[:space:]')"
  rssh "$(get TGT $s)" "$(get CTRL $s)" "mkdir -p -- $(get REMOTE $s)/proj && printf 'rw-marker-only-on-${s}-${NONCE}\n' > $(get REMOTE $s)/proj/marker-${s}.txt" \
    || fail "could not prepare remote ${s}"
done
if [[ -n "$(get HOST a)" && -n "$(get HOST b)" && "$(get HOST a)" != "$(get HOST b)" ]]; then
  pass "the two targets are different machines"
else
  fail "the two targets did not report different host names"
fi

cleanup() {
  for s in a b; do
    rssh "$(get TGT $s)" "$(get CTRL $s)" "rm -rf -- $(get REMOTE $s) $(get BROKER $s)" >/dev/null 2>&1 || true
    ssh -o "ControlPath=$(get CTRL $s)" -O exit "$(get TGT $s)" >/dev/null 2>&1 || true
    rm -rf "$(get LOCAL $s)"
  done
  rm -f "$LOG"
}
trap cleanup EXIT

run_session() { # run_session <a|b>
  local s="$1" t
  t="$(get TGT $s)"
  local proj="$(get LOCAL $s)/proj"
  local prompt="Use the bash tool exactly once and then stop. The command is: hostname; echo RW_F6_${s}_${NONCE}; cat marker-${s}.txt; echo made-by-${s}-${NONCE} > made-${s}.txt; sleep 20; ls. Do not use any other tool. Do not print the environment, tokens, or home directory."
  date +%s >"$RAW/f6-${s}.start"
  (
    cd "$proj" || exit 97
    if [[ "$HARNESS" == claude ]]; then
      if [[ -n "${RW_TOKEN_FILE:-}" && -s "$RW_TOKEN_FILE" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN=$(<"$RW_TOKEN_FILE")
        export CLAUDE_CODE_OAUTH_TOKEN
      fi
      CLAUDE_CODE_SHELL="$WRAP" \
        RW_SSH_TARGET="$t" \
        RW_PATH_MAP="$(get LOCAL $s)|$(get REMOTE $s)" \
        RW_TRANSPORT=broker \
        RW_BROKER_ROOT="$(get BROKER $s)" \
        RW_CONTROL_PATH="$(get CTRL $s)" \
        RW_CONTROL_PERSIST=10m \
        timeout 240 claude -p \
          --permission-mode bypassPermissions \
          --dangerously-skip-permissions \
          --allowedTools "Bash" \
          --disallowedTools "Edit,Write,NotebookEdit,Read,Grep,Glob" \
          --effort low \
          "$prompt Copy the raw output into your reply exactly as returned, in a code block, with no summary."
    else
      SHELL="$WRAP" \
        RW_SSH_TARGET="$t" \
        RW_PATH_MAP="$(get LOCAL $s)|$(get REMOTE $s)" \
        RW_TRANSPORT=broker \
        RW_BROKER_ROOT="$(get BROKER $s)" \
        RW_CONTROL_PATH="$(get CTRL $s)" \
        RW_CONTROL_PERSIST=10m \
        timeout 240 opencode --pure run -m opencode/big-pickle --auto "$prompt"
    fi
  ) >"$RAW/f6-${s}.out" 2>"$RAW/f6-${s}.err"
  echo $? >"$RAW/f6-${s}.rc"
  date +%s >"$RAW/f6-${s}.end"
}

rm -f "$RAW"/f6-*
run_session a &
pa=$!
# OpenCode keeps one local database; two processes opened in the same instant lock it.
sleep 6
run_session b &
pb=$!
wait "$pa" "$pb"

sa=$(<"$RAW/f6-a.start"); ea=$(<"$RAW/f6-a.end")
sb=$(<"$RAW/f6-b.start"); eb=$(<"$RAW/f6-b.end")
note "session_a: ${sa}..${ea} exit $(<"$RAW/f6-a.rc")"
note "session_b: ${sb}..${eb} exit $(<"$RAW/f6-b.rc")"
if [[ "$sa" -le "$eb" && "$sb" -le "$ea" ]]; then
  pass "the two sessions overlapped in time"
else
  fail "the two sessions did not overlap"
fi

for s in a b; do
  o=a
  [[ "$s" == a ]] && o=b
  both="$RAW/f6-${s}.both"
  cat "$RAW/f6-${s}.out" "$RAW/f6-${s}.err" >"$both"
  if grep -E -q 'sk-ant-|sk-or-v1-' "$both"; then
    rm -f "$both" "$RAW"/f6-*
    fail "session output held a credential; discarded"
    exit 1
  fi
  if grep -F -q "RW_F6_${s}_${NONCE}" "$both"; then
    pass "session ${s} ran its command"
  else
    fail "session ${s} did not print its own marker command output"
  fi
  if grep -F -q "rw-marker-only-on-${s}-${NONCE}" "$both"; then
    pass "session ${s} read the file only its own remote has"
  else
    fail "session ${s} did not read its own remote marker"
  fi
  if grep -F -q "$(get HOST $s)" "$both"; then
    pass "session ${s} printed its own remote host name"
  else
    fail "session ${s} did not print its own remote host name"
  fi
  if grep -F -q "$(get HOST $o)" "$both" || grep -F -q "rw-marker-only-on-${o}-${NONCE}" "$both" \
    || grep -F -q "RW_F6_${o}_${NONCE}" "$both" || grep -F -q "made-${o}.txt" "$both" || grep -F -q "made-by-${o}-" "$both"; then
    fail "session ${s} output holds the other session's host, marker or file"
  else
    pass "session ${s} output holds nothing from the other session"
  fi
  # The remote that session s used holds s's file, and the other remote does not.
  # Decide from stdout, not the exit status: some ssh targets (mini0) always return 0.
  if [[ -n "$(rssh "$(get TGT $s)" "$(get CTRL $s)" "grep -F made-by-${s}-${NONCE} $(get REMOTE $s)/proj/made-${s}.txt 2>/dev/null")" ]]; then
    pass "remote ${s} holds the file session ${s} created"
  else
    fail "remote ${s} lacks the file session ${s} created"
  fi
  if [[ -n "$(rssh "$(get TGT $o)" "$(get CTRL $o)" "find /tmp -maxdepth 3 \( -name 'made-${s}.txt' -o -name 'marker-${s}.txt' \) -path '*${NONCE}*' 2>/dev/null")" ]]; then
    fail "remote ${o} holds a file that belongs to session ${s}"
  else
    pass "remote ${o} holds no file that belongs to session ${s}"
  fi
  # Local mirror of s must not hold the other session's files.
  if find "$(get LOCAL $s)" -name "*-${o}.txt" -o -name "made-${o}.txt" | grep -q .; then
    fail "local tree of session ${s} holds the other session's file"
  else
    pass "local tree of session ${s} holds no file from the other session"
  fi
done

note "RESULT: see passes"
out="$EVID/f6.log"
[[ "$HARNESS" == claude ]] && out="$EVID/f6-claude.log"
{
  printf 'id: f6\nharness: %s\n' "$HARNESS"
  printf 'when: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'passes: %s\n' "$PASSES"
  printf 'fails: %s\n' "$FAILS"
  # Host names, users and nonces stay out of the committed log.
  sed -e "s/$(get HOST a)/remote-a/g" -e "s/$(get HOST b)/remote-b/g" -e "s/${NONCE}/NONCE/g" "$LOG"
} >"$RAW/f6.log"
perl -pe 'BEGIN{$h=$ENV{HOME}} s/\Q$h\E/\/Users\/user/g; s/\b\d{1,3}(?:\.\d{1,3}){3}\b/redacted-ip/g' "$RAW/f6.log" >"$out"
[[ "$FAILS" -eq 0 ]]
