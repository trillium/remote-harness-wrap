#!/bin/bash
# F4. Kill the link during a mirror push. The remote file stays the previous
# complete bytes, or it is absent. It is never a short prefix of the new bytes.
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
  proof_finish f4
}
# shellcheck source=../../src/mirror.sh
. "$RW_ROOT/src/mirror.sh"

nonce="f4${RANDOM}${RANDOM}"
local_dir=$(mktemp -d "/tmp/rw-whole-local.XXXXXX")
remote_dir="/tmp/rw-whole-${nonce}"
export RW_SSH_TARGET RW_PATH_MAP="${local_dir}|${remote_dir}"
cleanup() {
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o LogLevel=ERROR -T "$RW_SSH_TARGET" \
    "rm -rf -- $(printf '%q' "$remote_dir") /tmp/rw-mirror-stage.*" >/dev/null 2>&1 || true
  rm -rf "$local_dir" "${local_dir}.rw-manifest"
}
trap cleanup EXIT

old='WHOLE'
proof_ssh "mkdir -p -- $(printf '%q' "$remote_dir") && printf '%s\n' $(printf '%q' "$old") > $(printf '%q' "$remote_dir/payload")" \
  || fail "could not seed the remote file"
mirror_pull || fail "initial pull failed"
printf '%s\n' "$old" >"$local_dir/payload"
# A multi-megabyte replacement. The push is bandwidth-limited so the kill
# lands while rsync is still filling the staging directory.
dd if=/dev/zero bs=1024 count=8192 2>/dev/null | tr '\0' 'N' >"$local_dir/payload"
new_size=$(wc -c <"$local_dir/payload" | tr -d ' ')
note "new_bytes=${new_size}"

RW_MIRROR_BWLIMIT=32 mirror_push &
push_pid=$!
killed=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  kids=$(pgrep -P "$push_pid" || true)
  for kid in $kids; do
    comm=$(ps -p "$kid" -o comm= 2>/dev/null || true)
    if [[ "$comm" == *rsync* ]]; then
      kill -TERM "$kid" 2>/dev/null || true
      killed=1
    fi
  done
  [[ "$killed" -eq 1 ]] && break
  sleep 0.25
done
wait "$push_pid" || true
note "rsync_killed=${killed}"
if [[ "$killed" -ne 1 ]]; then
  fail "the transfer finished before it could be killed"
else
  pass "the transfer was killed while rsync was running"
fi

result=$(proof_ssh python3 - "$remote_dir/payload" "$old" "$new_size" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
old = (sys.argv[2] + "\n").encode()
new_size = int(sys.argv[3])
if not p.exists():
    sys.stdout.write("absent\n")
    raise SystemExit
data = p.read_bytes()
if data == old:
    sys.stdout.write("previous-whole\n")
elif data and set(data) <= {ord("N")} and len(data) < new_size:
    sys.stdout.write("prefix\n")
elif len(data) == new_size and set(data) <= {ord("N")}:
    sys.stdout.write("complete-new\n")
else:
    sys.stdout.write("other\n")
PY
)
result=$(printf '%s' "$result" | tr -d '\r\n')
note "payload=${result}"
case "$result" in
  previous-whole | absent)
    pass "remote file is whole or absent after the dropped link"
    ;;
  prefix)
    fail "remote file is a partial write"
    ;;
  complete-new)
    fail "the new file was published before the kill"
    ;;
  *)
    fail "remote file is not a previous whole file or absent"
    ;;
esac

# A finished push still publishes a whole small file.
printf 'AFTER\n' >"$local_dir/payload"
if mirror_push; then
  pass "a later push completed"
else
  fail "a later push failed"
fi
after=$(proof_ssh "cat $(printf '%q' "$remote_dir/payload")" | tr -d '\r')
if [[ "$after" == "AFTER" ]]; then
  pass "the completed push left the whole new file"
else
  fail "the completed push did not leave the new file"
fi
proof_finish f4
