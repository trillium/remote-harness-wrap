#!/bin/bash
# A11. A command that needs a terminal fails clearly. ssh is invoked with -T,
# and the broker opens the remote command with stdin on /dev/null.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

proj="${RW_LOCAL_ROOT}/proj"
script='tty_rc=$(tty >/dev/null 2>&1; printf "%s" "$?"); printf "tty_rc:%s\n" "$tty_rc"; read -r line; rrc=$?; printf "read_rc:%s line_len:%s\n" "$rrc" "${#line}"; exit "$rrc"'
out="${RW_RAW}/a11-out.txt"
err="${RW_RAW}/a11-err.txt"
printf 'typed-line\n' | exec_wrapper "$proj" "$script" >"$out" 2>"$err"
rc=$?
note "pipe_exit: ${rc}"
note "pipe_stdout: $(tr '\n' ' ' <"$out")"
if [[ -s "$err" ]]; then
  note "pipe_stderr: present"
else
  note "pipe_stderr: empty"
fi
if grep -F -q 'tty_rc:1' "$out"; then
  pass "remote command reports that it has no tty"
else
  fail "remote command did not report the missing tty"
fi
if grep -F -q 'read_rc:1' "$out" && grep -F -q 'line_len:0' "$out"; then
  pass "read returns non-zero on immediate EOF and does not see the piped line"
else
  fail "read did not fail closed"
fi
if [[ "$rc" -ne 0 ]]; then
  pass "wrapper exits non-zero when read fails"
else
  fail "wrapper exited 0"
fi

pty_out="${RW_RAW}/a11-pty.txt"
python3 - "$RW_WRAP" "$proj" "$pty_out" <<'PY'
import os, pty, select, sys, time
wrap, cwd, dest = sys.argv[1:]
script = r'''tty_rc=$(tty >/dev/null 2>&1; printf "%s" "$?"); printf "tty_rc:%s\n" "$tty_rc"; read -r line; rrc=$?; printf "read_rc:%s line_len:%s\n" "$rrc" "${#line}"; exit "$rrc"'''
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execve(wrap, [wrap, "-c", script], os.environ.copy())
try:
    os.write(fd, b"typed-line\n")
except OSError:
    pass
buf = b""
status = 1
deadline = time.time() + 20
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.5)
    if ready:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            buf += chunk
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        status = st
        break
else:
    os.kill(pid, 15)
    os.waitpid(pid, 0)
    status = 124
text = buf.decode("utf-8", "replace")
open(dest, "w").write(f"pty_status: {status}\n{text}\n")
PY
note "pty_stdout: $(tr '\n' ' ' <"$pty_out")"
if grep -F -q 'tty_rc:1' "$pty_out"; then
  pass "a local pty still does not give the remote command a tty"
else
  fail "pty case did not report the missing tty"
fi
note "RESULT: interactive input is not forwarded; tty is absent; read exits 1"
coverage_finish a11
