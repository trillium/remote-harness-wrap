#!/bin/bash
# B6. Modes, symlinks, case, unicode, a large file, and version control.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"

IMG=""
MNT=""
SAVED_LOCAL="$RW_LOCAL_ROOT"
SAVED_MAP="$RW_PATH_MAP"

detach_image() {
  if [[ -n "$MNT" ]]; then
    hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
    rm -rf "$MNT"
    MNT=""
  fi
  if [[ -n "$IMG" ]]; then
    rm -f "$IMG"
    IMG=""
  fi
  RW_LOCAL_ROOT="$SAVED_LOCAL"
  RW_PATH_MAP="$SAVED_MAP"
}

case_kind() {
  local root="$1" probe fa fb
  probe="$root/case-probe-$$"
  mkdir -p "$probe"
  printf 'A' >"$probe/Foo"
  printf 'B' >"$probe/foo"
  fa=$(cat "$probe/Foo")
  fb=$(cat "$probe/foo")
  rm -rf "$probe"
  if [[ "$fa" == A && "$fb" == B ]]; then
    printf 'sensitive'
  else
    printf 'folding'
  fi
}

remote_case=$(proof_ssh 'd=$(mktemp -d /tmp/rw-bd-case.XXXXXX); printf A > "$d/Foo"; printf B > "$d/foo"; fa=$(cat "$d/Foo"); fb=$(cat "$d/foo"); rm -rf "$d"; if [ "$fa" = A ] && [ "$fb" = B ]; then echo sensitive; else echo folding; fi' || true)
remote_case=$(printf '%s' "$remote_case" | tr -d '\r\n')
note "remote_case=$remote_case"

local_case=$(case_kind "$RW_LOCAL_ROOT")
if [[ "$remote_case" == sensitive && "$local_case" != sensitive ]]; then
  IMG=$(mktemp /tmp/rw-bd-cs.XXXXXX.dmg)
  rm -f "$IMG"
  MNT=$(mktemp -d /tmp/rw-bd-mnt.XXXXXX)
  if hdiutil create -size 64m -fs "Case-sensitive APFS" -volname rwbdcs "$IMG" >/dev/null &&
    hdiutil attach "$IMG" -nobrowse -mountpoint "$MNT" >/dev/null; then
    RW_LOCAL_ROOT="$MNT"
    RW_PATH_MAP="${RW_LOCAL_ROOT}|${RW_REMOTE_ROOT}"
    local_case=$(case_kind "$RW_LOCAL_ROOT")
    note "provider_case_volume=$local_case"
  else
    note "provider_case_volume=unavailable"
    detach_image
    local_case=$(case_kind "$RW_LOCAL_ROOT")
  fi
fi
note "provider_case=$local_case"

if [[ "$remote_case" == sensitive && "$local_case" == sensitive ]]; then
  printf 'upper\n' >"$RW_LOCAL_ROOT/Foo"
  printf 'lower\n' >"$RW_LOCAL_ROOT/foo"
  if plane_push && plane_pull; then
    up=$(cat "$RW_LOCAL_ROOT/Foo")
    low=$(cat "$RW_LOCAL_ROOT/foo")
    up=${up%$'\n'}
    low=${low%$'\n'}
    if [[ "$up" == upper && "$low" == lower ]]; then
      pass "case-sensitive names round-trip"
    else
      fail "case-sensitive names did not round-trip"
    fi
  else
    fail "case-sensitive sync failed"
  fi
elif [[ "$remote_case" == folding ]]; then
  printf 'only\n' >"$RW_LOCAL_ROOT/Foo"
  if plane_push && plane_pull; then
    if [[ -f "$RW_LOCAL_ROOT/Foo" || -f "$RW_LOCAL_ROOT/foo" ]]; then
      pass "case-folding remote keeps one name and the mirror matches"
    else
      fail "case-folding name disappeared"
    fi
  else
    fail "case-folding sync failed"
  fi
else
  fail "could not compare case behavior"
fi

python3 -c 'import os,sys; open(os.path.join(sys.argv[1], "naïve-文件.txt"), "w", encoding="utf-8").write("uni\n")' "$RW_LOCAL_ROOT"
printf 'target\n' >"$RW_LOCAL_ROOT/link-target.txt"
ln -sf link-target.txt "$RW_LOCAL_ROOT/the-link"
printf 'mode\n' >"$RW_LOCAL_ROOT/mode.txt"
chmod 640 "$RW_LOCAL_ROOT/mode.txt"
printf 'exec\n' >"$RW_LOCAL_ROOT/mode.sh"
chmod 755 "$RW_LOCAL_ROOT/mode.sh"
python3 -c 'open(__import__("sys").argv[1],"wb").write(b"\0"*(8*1024*1024))' "$RW_LOCAL_ROOT/large.bin"
before_sha=$(plane_sha "$RW_LOCAL_ROOT/large.bin")

if plane_push; then
  pass "attribute push exited 0"
else
  fail "attribute push failed"
fi

uni=$(plane_remote_py "import pathlib; p=pathlib.Path('$RW_REMOTE_ROOT')/'naïve-文件.txt'; print(p.read_text(encoding='utf-8').strip() if p.exists() else 'missing')" || true)
uni=$(printf '%s' "$uni" | tr -d '\r\n')
if [[ "$uni" == uni ]]; then
  pass "unicode name round-trips"
else
  fail "unicode name mismatch"
fi

link=$(plane_remote_py "import os; print(os.readlink('$RW_REMOTE_ROOT/the-link'))" || true)
link=$(printf '%s' "$link" | tr -d '\r\n')
if [[ "$link" == link-target.txt ]]; then
  pass "symlink round-trips"
else
  fail "symlink mismatch"
fi

mode_file=$(plane_remote_py "import os; print(oct(os.lstat('$RW_REMOTE_ROOT/mode.txt').st_mode & 0o777))" || true)
mode_exec=$(plane_remote_py "import os; print(oct(os.lstat('$RW_REMOTE_ROOT/mode.sh').st_mode & 0o777))" || true)
mode_file=$(printf '%s' "$mode_file" | tr -d '\r\n')
mode_exec=$(printf '%s' "$mode_exec" | tr -d '\r\n')
note "remote_mode_file=$mode_file remote_mode_exec=$mode_exec"
if [[ "$mode_file" == 0o640 && "$mode_exec" == 0o755 ]]; then
  pass "file modes round-trip"
else
  fail "file modes mismatch"
fi

remote_sha=$(plane_remote_py "import hashlib; print(hashlib.sha256(open('$RW_REMOTE_ROOT/large.bin','rb').read()).hexdigest())" || true)
remote_sha=$(printf '%s' "$remote_sha" | tr -d '\r\n')
if [[ -n "$before_sha" && "$before_sha" == "$remote_sha" ]]; then
  pass "large file checksum matches"
else
  fail "large file checksum mismatch"
fi

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Proof
export GIT_AUTHOR_EMAIL=proof@example.com
export GIT_COMMITTER_NAME=Proof
export GIT_COMMITTER_EMAIL=proof@example.com
repo="$RW_LOCAL_ROOT/repo"
mkdir -p "$repo"
if git -C "$repo" init -b main >/dev/null 2>&1; then
  :
else
  git -C "$repo" init >/dev/null
  git -C "$repo" checkout -b main >/dev/null 2>&1 || true
fi
git -C "$repo" config user.name Proof
git -C "$repo" config user.email proof@example.com
printf 'one\n' >"$repo/tracked.txt"
git -C "$repo" -c core.hooksPath=/dev/null add tracked.txt
git -C "$repo" -c core.hooksPath=/dev/null commit -m one >/dev/null
printf 'two\n' >"$repo/tracked.txt"
git -C "$repo" -c core.hooksPath=/dev/null add tracked.txt
git -C "$repo" -c core.hooksPath=/dev/null commit -m two >/dev/null
git -C "$repo" -c core.hooksPath=/dev/null checkout --quiet HEAD~1
if plane_push; then
  pass "version-control push exited 0"
else
  fail "version-control push failed"
fi
remote_tracked=$(proof_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/repo/tracked.txt")" || true)
remote_tracked=${remote_tracked//$'\r'/}
remote_tracked=${remote_tracked%$'\n'}
status_out=$(proof_ssh "git -C $(printf '%q' "$RW_REMOTE_ROOT/repo") -c core.hooksPath=/dev/null status --porcelain" || true)
status_out=${status_out//$'\r'/}
if [[ "$remote_tracked" == one && -z "$status_out" ]]; then
  pass "checkout of the older commit is what the remote has"
else
  fail "checkout did not land on the remote"
fi
git -C "$repo" -c core.hooksPath=/dev/null checkout --quiet main
plane_push || fail "return-to-main push failed"
remote_tracked=$(proof_ssh "cat $(printf '%q' "$RW_REMOTE_ROOT/repo/tracked.txt")" || true)
remote_tracked=${remote_tracked//$'\r'/}
remote_tracked=${remote_tracked%$'\n'}
if [[ "$remote_tracked" == two ]]; then
  pass "later commit is what the remote has"
else
  fail "later commit did not land on the remote"
fi

detach_image
proof_finish b6
