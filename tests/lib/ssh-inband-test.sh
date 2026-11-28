#!/bin/bash
# Guards the rule that no test helper trusts the exit status ssh reports.
#
#   tests/lib/ssh-inband-test.sh
#
# 1. Behaviour: a fake `ssh` that always exits 0, as the Tailscale SSH server
#    does, runs the remote command locally. Every helper must still return the
#    remote command's real status, keep stdout clean, pass stdin, keep stderr.
# 2. Lint: the helpers must route through rw_ssh_inband, and any other raw
#    `ssh` call in tests/ whose status is read must carry a
#    `# rw-raw-ssh-rc-ok: <reason>` comment on one of the two lines above.
# Runs on this machine only; no network and no remote host.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PASSES=0
FAILS=0
ok() { PASSES=$((PASSES + 1)); printf 'PASS: %s\n' "$*"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rw-inband-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# Fake ssh: skip options and the target, run the command string in sh, then
# report success whatever happened.
cat >"$tmp/bin/ssh" <<'FAKE'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift 2 ;;
    -T | -n | -q) shift ;;
    *) break ;;
  esac
done
shift # target
sh -c "$*"
exit 0
FAKE
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"
export RW_SSH_TARGET=fake-target RW_CONTROL_PATH="$tmp/ctl-%C"

# Precondition: the fake does hide the status, so the checks below mean something.
ssh -T fake-target 'exit 3'
[[ $? -eq 0 ]] && ok "fake ssh reports 0 for a command that exits 3" || bad "fake ssh is not hiding the status"

check_helper() { # check_helper <name> <function>
  local name="$1" fn="$2" out err rc
  "$fn" 'exit 3' >/dev/null 2>&1; rc=$?
  [[ $rc -eq 3 ]] && ok "$name: exit 3 comes back as 3" || bad "$name: exit 3 came back as $rc"
  "$fn" false >/dev/null 2>&1; rc=$?
  [[ $rc -eq 1 ]] && ok "$name: false comes back as 1" || bad "$name: false came back as $rc"
  "$fn" 'grep -q nomatch /dev/null' >/dev/null 2>&1; rc=$?
  [[ $rc -eq 1 ]] && ok "$name: a failed grep comes back as 1" || bad "$name: a failed grep came back as $rc"
  "$fn" true >/dev/null 2>&1; rc=$?
  [[ $rc -eq 0 ]] && ok "$name: true comes back as 0" || bad "$name: true came back as $rc"
  "$fn" 'if false; then echo x; fi' >/dev/null 2>&1; rc=$?
  [[ $rc -eq 0 ]] && ok "$name: a false condition with no else comes back as 0" || bad "$name: came back as $rc"
  out=$("$fn" 'printf out; printf err >&2; exit 4' 2>"$tmp/err"); rc=$?
  err=$(cat "$tmp/err")
  [[ $rc -eq 4 && "$out" == out ]] && ok "$name: stdout is clean and status 4 survives" || bad "$name: out='$out' rc=$rc"
  [[ "$err" == err ]] && ok "$name: remote stderr is kept and the marker is removed" || bad "$name: stderr was '$err'"
  out=$(printf 'from-stdin' | "$fn" 'cat; exit 5'); rc=$?
  [[ $rc -eq 5 && "$out" == from-stdin ]] && ok "$name: stdin passes through with status 5" || bad "$name: stdin out='$out' rc=$rc"
  out=$("$fn" bash -s <<'BODY'
echo heredoc-ran
exit 6
BODY
  ); rc=$?
  [[ $rc -eq 6 && "$out" == heredoc-ran ]] && ok "$name: a heredoc body runs and its status 6 survives" || bad "$name: heredoc out='$out' rc=$rc"
  "$fn" 'exit 9 # trailing comment' >/dev/null 2>&1; rc=$?
  [[ $rc -eq 9 ]] && ok "$name: a trailing comment does not eat the status" || bad "$name: comment case came back as $rc"
}

# shellcheck source=proof.sh
. "$ROOT/tests/lib/proof.sh"
# shellcheck source=../exec/lib.sh
. "$ROOT/tests/exec/lib.sh"
check_helper proof_ssh proof_ssh
check_helper exec_ssh exec_ssh

# No marker and ssh claims success: that is a failure, not a pass.
cat >"$tmp/bin/ssh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
proof_ssh true >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "a session that never ran the command is not reported as success" || bad "missing marker returned 0"

# Lint 1: helper bodies go through rw_ssh_inband.
for pair in "tests/lib/proof.sh:proof_ssh" "tests/exec/lib.sh:exec_ssh"; do
  f="${pair%%:*}"; fn="${pair##*:}"
  body=$(awk -v fn="$fn" '$0 ~ "^"fn"\\(\\)" {on=1} on {print} on && /^}/ {exit}' "$ROOT/$f")
  if grep -q 'rw_ssh_inband ssh' <<<"$body"; then
    ok "lint: $fn calls rw_ssh_inband"
  else
    bad "lint: $fn does not call rw_ssh_inband (it trusts raw ssh status)"
  fi
done

# Lint 2: raw ssh calls whose status is read must be marked.
lint_raw() { # lint_raw <file>  -- prints offending line numbers
  awk '
    function raw(l) { return l ~ /(^|[[:space:];&|(]|then )(\/usr\/bin\/)?ssh[[:space:]]+-/ && l !~ /rw_ssh_inband/ && l !~ /ssh -G/ && l !~ /-O exit/ && l !~ /^[[:space:]]*#/ }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (!raw(line[i])) continue
        # the call ends at the first line that does not end in a backslash
        j = i; while (line[j] ~ /\\$/ && j < NR) j++
        window = line[i]; for (k = i + 1; k <= j + 3 && k <= NR; k++) window = window "\n" line[k]
        reads = (line[i] ~ /(if|!)[[:space:]]+(env |SSH_AUTH_SOCK=[^ ]* )*ssh/) || (window ~ /\$\?/) || (line[j] ~ /\|\| [a-z_]*rc=\$\?/)
        if (!reads) continue
        if (line[i-1] ~ /rw-raw-ssh-rc-ok:/ || line[i-2] ~ /rw-raw-ssh-rc-ok:/ || line[i] ~ /rw-raw-ssh-rc-ok:/) continue
        print i
      }
    }' "$1"
}
bad_sites=0
while IFS= read -r f; do
  [[ "$f" == "$ROOT/tests/lib/ssh-inband"* ]] && continue
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    bad "lint: ${f#"$ROOT"/}:$n reads the status of a raw ssh call"
    bad_sites=$((bad_sites + 1))
  done < <(lint_raw "$f")
done < <(find "$ROOT/tests" -name '*.sh' -type f | sort)
[[ $bad_sites -eq 0 ]] && ok "lint: no unmarked raw ssh call has its status read"

# The lint must itself catch a violation.
printf '#!/bin/bash\nif ssh -T host true; then echo up; fi\nssh -o X host false\nrc=$?\n' >"$tmp/violation.sh"
[[ -n "$(lint_raw "$tmp/violation.sh")" ]] && ok "lint: a planted raw-ssh status check is caught" || bad "lint: a planted violation was not caught"

printf 'passes: %s\nfails: %s\n' "$PASSES" "$FAILS"
[[ $FAILS -eq 0 ]]
