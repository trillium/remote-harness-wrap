#!/bin/bash
# B4. Search sees a fresh token, with and without memory-mapped reads.
# The mirror is searched after each pull. The logging rg is searched
# without a local copy, so a hit has to come from the remote.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
plane_begin "$@"
note "plane: ssh-sync"
RG="$RW_ROOT/src/rg"
RG_LOG="$RW_RAW/b4-$(proof_label).log"
: >"$RG_LOG"

miss_mmap=0
miss_nommap=0
start=$(date +%s)
i=1
while [[ $i -le 50 ]]; do
  token="b4m-$i"
  if ! proof_ssh "printf '%s\n' $(printf '%q' "$token") > $(printf '%q' "$RW_REMOTE_ROOT/token.txt")"; then
    miss_mmap=$((miss_mmap + 1))
    miss_nommap=$((miss_nommap + 1))
    i=$((i + 1))
    continue
  fi
  if ! plane_pull; then
    miss_mmap=$((miss_mmap + 1))
    miss_nommap=$((miss_nommap + 1))
    i=$((i + 1))
    continue
  fi
  if ! rg --mmap --no-config -q -F "$token" "$RW_LOCAL_ROOT/token.txt"; then
    miss_mmap=$((miss_mmap + 1))
  fi
  if ! rg --no-mmap --no-config -q -F "$token" "$RW_LOCAL_ROOT/token.txt"; then
    miss_nommap=$((miss_nommap + 1))
  fi
  i=$((i + 1))
done
end=$(date +%s)
note "mirror n=50 seconds=$((end - start)) miss_mmap=$miss_mmap miss_nommap=$miss_nommap"
if [[ $miss_mmap -eq 0 && $miss_nommap -eq 0 ]]; then
  pass "mirror search matched 50 fresh tokens in both modes"
else
  fail "mirror search misses mmap=$miss_mmap nommap=$miss_nommap"
fi

rm -f "$RW_LOCAL_ROOT/token.txt"
fwd_mmap=0
fwd_nommap=0
start=$(date +%s)
i=1
while [[ $i -le 50 ]]; do
  token="b4f-$i"
  if ! proof_ssh "printf '%s\n' $(printf '%q' "$token") > $(printf '%q' "$RW_REMOTE_ROOT/token.txt")"; then
    fwd_mmap=$((fwd_mmap + 1))
    fwd_nommap=$((fwd_nommap + 1))
    i=$((i + 1))
    continue
  fi
  if ! (
    cd "$RW_LOCAL_ROOT" &&
      RW_SSH_TARGET="$RW_SSH_TARGET" \
      RW_PATH_MAP="$RW_PATH_MAP" \
      RW_RG_LOG="$RG_LOG" \
      RW_CONTROL_PATH="$RW_CONTROL_PATH" \
      "$RG" --mmap --no-config -q -F "$token" token.txt
  ); then
    fwd_mmap=$((fwd_mmap + 1))
  fi
  if ! (
    cd "$RW_LOCAL_ROOT" &&
      RW_SSH_TARGET="$RW_SSH_TARGET" \
      RW_PATH_MAP="$RW_PATH_MAP" \
      RW_RG_LOG="$RG_LOG" \
      RW_CONTROL_PATH="$RW_CONTROL_PATH" \
      "$RG" --no-mmap --no-config -q -F "$token" token.txt
  ); then
    fwd_nommap=$((fwd_nommap + 1))
  fi
  i=$((i + 1))
done
end=$(date +%s)
note "logging-rg n=50 seconds=$((end - start)) miss_mmap=$fwd_mmap miss_nommap=$fwd_nommap"
forwards=$(grep -c 'forward=1' "$RG_LOG" || true)
note "logging-rg forward_lines=$forwards"
if [[ $fwd_mmap -eq 0 && $fwd_nommap -eq 0 && $forwards -ge 100 ]]; then
  pass "logging rg matched 50 fresh tokens in both modes"
else
  fail "logging rg misses mmap=$fwd_mmap nommap=$fwd_nommap forwards=$forwards"
fi
proof_finish b4
