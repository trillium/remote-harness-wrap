#!/bin/bash
# F2. An unmodified harness fixes a failing test in a repository that exists
# only on the remote. The test and the commit run on the remote. Stopping the
# session removes the provider mirror.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../lib/proof.sh
. "$HERE/../lib/proof.sh"
export RW_EVIDENCE_PLANE=whole
proof_prepare "$@"
RW_SSH_TARGET="${RW_SSH_TARGET:-}"
[[ -n "$RW_SSH_TARGET" ]] || {
  note "missing ssh target"
  FAILS=$((FAILS + 1))
  proof_finish f2
}

harness="${RW_F2_HARNESS:-}"
if [[ -z "$harness" ]]; then
  if [[ -n "${RW_TOKEN_FILE:-}" && -s "${RW_TOKEN_FILE:-}" ]] && command -v claude >/dev/null 2>&1; then
    harness=claude
  elif command -v opencode >/dev/null 2>&1; then
    harness=opencode
  fi
fi
if [[ "$harness" == claude ]]; then
  harness_bin=$(command -v claude || true)
elif [[ "$harness" == opencode ]]; then
  harness_bin=$(command -v opencode || true)
else
  harness_bin=""
fi
if [[ -z "$harness_bin" || ! -x "$harness_bin" ]]; then
  fail "no harness on PATH"
  proof_finish f2
fi
note "harness=${harness}"
sum_before=$(shasum -a 256 "$harness_bin" | awk '{print $1}')
note "checksum_before=${sum_before}"

nonce="f2${RANDOM}${RANDOM}"
remote_dir="/tmp/rw-pkg-${nonce}"
local_dir="/tmp/rw-bd-f2-${nonce}"
state=$(mktemp -d "/tmp/rw-bd-state.XXXXXX")
export RW_STATE="$state"
export RW_CONTROL_PATH="/tmp/rw-f2-${nonce}-%C"
rm -rf "$local_dir" "${local_dir}.rw-manifest"

cleanup_left() {
  RW_STATE="$state" "$RW_BIN" down >/dev/null 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR -T "$RW_SSH_TARGET" \
    "rm -rf -- $(printf '%q' "$remote_dir")" >/dev/null 2>&1 || true
  rm -rf "$local_dir" "${local_dir}.rw-manifest" "$state"
}
trap cleanup_left EXIT

qdir=$(printf '%q' "$remote_dir")
if ! proof_ssh "bash -s" <<EOF
set -eu
rm -rf -- $qdir
mkdir -p -- $qdir
cd $qdir
git init -q
git config user.email fixture@example.com
git config user.name fixture
git config commit.gpgsign false
mkdir -p hooks
git config core.hooksPath hooks
cat > add.py <<'PY'
def add(a, b):
    return a - b
PY
cat > test_add.py <<'PY'
from add import add

def test_add():
    got = add(2, 3)
    if got != 5:
        raise SystemExit("fail %s" % got)
    print("RW_F2_PASS")

if __name__ == "__main__":
    test_add()
PY
printf 'keep\n' > "f2keep${nonce}.txt"
git add add.py test_add.py "f2keep${nonce}.txt"
git commit -qm 'broken add'
EOF
then
  fail "could not create the remote fixture"
  proof_finish f2
fi

if proof_ssh "cd $qdir && python3 test_add.py" >/dev/null 2>&1; then
  fail "fixture test already passed on the remote"
else
  pass "fixture test fails on the remote before the session"
fi
if [[ -e "$local_dir" ]]; then
  fail "provider already had the project directory"
else
  pass "provider has no project directory before the session"
fi

prompt='The test in test_add.py fails. Fix only add.py so python3 test_add.py prints RW_F2_PASS and exits 0. Use the Bash tool to run that test. Then use the Bash tool to commit the fix: git add add.py && git commit -m fix-add. Do not change test_add.py. Do not print the environment, the home directory, or any credential.'
run_log="${RW_RAW}/f2-run.out"
run_err="${RW_RAW}/f2-run.err"
if [[ "$harness" == claude ]]; then
  [[ -n "${RW_TOKEN_FILE:-}" && -s "${RW_TOKEN_FILE}" ]] || {
    fail "claude needs RW_TOKEN_FILE"
    proof_finish f2
  }
  CLAUDE_CODE_OAUTH_TOKEN=$(<"$RW_TOKEN_FILE") \
    RW_STATE="$state" RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$remote_dir" --local "$local_dir" -- \
    "$harness_bin" -p --model haiku --permission-mode bypassPermissions \
    --dangerously-skip-permissions --allowedTools Bash --effort low \
    "$prompt" >"$run_log" 2>"$run_err" &
else
  RW_STATE="$state" RW_CONTROL_PATH="$RW_CONTROL_PATH" \
    "$RW_BIN" run --remote "$RW_SSH_TARGET" --project "$remote_dir" --local "$local_dir" -- \
    "$harness_bin" --pure run -m opencode/big-pickle --auto "$prompt" \
    >"$run_log" 2>"$run_err" &
fi
run_pid=$!
ticks=0
while kill -0 "$run_pid" 2>/dev/null && [[ "$ticks" -lt 300 ]]; do
  sleep 1
  ticks=$((ticks + 1))
done
if kill -0 "$run_pid" 2>/dev/null; then
  RW_STATE="$state" "$RW_BIN" down >/dev/null 2>&1 || true
  wait "$run_pid" 2>/dev/null || true
  note "harness_exit=124"
  fail "harness did not finish"
else
  wait "$run_pid" 2>/dev/null || harness_rc=$?
  note "harness_exit=${harness_rc:-0}"
fi
proof_reject_secrets "$run_log" || true
proof_reject_secrets "$run_err" || true

remote_out=$(proof_ssh "cd $qdir && python3 test_add.py" 2>"${RW_RAW}/f2-test.err" || true)
if printf '%s\n' "$remote_out" | grep -F -q 'RW_F2_PASS'; then
  pass "the fixed test passes on the remote"
else
  fail "the test does not pass on the remote"
fi
commits=$(proof_ssh "git -C $qdir rev-list --count HEAD" 2>/dev/null || true)
commits=$(printf '%s' "$commits" | tr -d '\r\n')
note "remote_commit_count=${commits:-0}"
subject=$(proof_ssh "git -C $qdir log -1 --format=%s" 2>/dev/null || true)
subject=$(printf '%s' "$subject" | tr -d '\r')
if [[ "$commits" -ge 2 ]]; then
  pass "the commit landed on the remote"
else
  fail "the remote repository does not have a new commit"
fi
if [[ "$subject" == "fix-add" ]]; then
  note "commit_subject=fix-add"
else
  note "commit_subject=other"
fi
if proof_ssh "git -C $qdir rev-parse --abbrev-ref HEAD" >/dev/null 2>&1; then
  pass "the remote path is still a git repository"
else
  fail "the remote path is not a git repository"
fi

down_out=$(RW_STATE="$state" "$RW_BIN" down 2>&1 || true)
note "stop_command=rw-down"
if printf '%s\n' "$down_out" | grep -F -q 'project=not-created-by-rw'; then
  pass "stop left the pre-existing remote project in place"
else
  fail "stop did not report the remote project as pre-existing"
fi
if [[ ! -e "$local_dir" && ! -e "${local_dir}.rw-manifest" ]]; then
  pass "stop removed the provider project directory"
else
  fail "provider project directory still exists"
fi
marker="f2keep${nonce}.txt"
hits=$(find /tmp /private/tmp -name "$marker" 2>/dev/null | wc -l | tr -d ' ')
note "provider_marker_hits=${hits}"
if [[ "$hits" == 0 ]]; then
  pass "no copy of the project marker remains on the provider"
else
  fail "a project file remains on the provider"
fi
if proof_ssh "test -d $qdir && echo present" | grep -q present; then
  pass "remote project still exists after stop"
else
  fail "remote project disappeared"
fi

sum_after=$(shasum -a 256 "$harness_bin" | awk '{print $1}')
note "checksum_after=${sum_after}"
if [[ "$sum_before" == "$sum_after" && -n "$sum_before" ]]; then
  pass "harness checksum is unchanged"
else
  fail "harness checksum changed"
fi
proof_finish f2
