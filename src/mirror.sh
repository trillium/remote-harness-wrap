#!/bin/bash
# Rsync barrier for one path map.
#
# mirror_push copies provider writes onto the remote before a wrapped command.
# mirror_pull copies the remote tree back into the local mirror after it.
# Both stay inside RW_PATH_MAP. A transfer that stops early does not publish:
# rsync lands in a staging directory, and mirror-publish.py replaces each
# destination path only after that copy is complete.
#
# A sibling file "<local>.rw-manifest" remembers the last pull. A path that
# was in that list and is gone locally is removed on the remote at the next
# push. Remote-only paths are left alone until a pull has seen them, so the
# first push cannot wipe a tree the provider has not mirrored yet.

# shellcheck source=path-map.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path-map.sh"

mirror_src() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

mirror_die() {
  printf 'mirror: %s\n' "$*" >&2
  return 1
}

mirror_rsh() {
  printf 'ssh -o ControlMaster=auto -o ControlPersist=%s -o ControlPath=%s -o BatchMode=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PubkeyAuthentication=yes -o NumberOfPasswordPrompts=0 -o ConnectTimeout=%s -o LogLevel=ERROR' \
    "${RW_CONTROL_PERSIST:-30m}" \
    "${RW_CONTROL_PATH:-/tmp/rw-exec-%C}" \
    "${RW_CONNECT_TIMEOUT:-8}"
}

mirror_ssh() {
  # shellcheck disable=SC2046
  ssh \
    -o ControlMaster=auto \
    -o "ControlPersist=${RW_CONTROL_PERSIST:-30m}" \
    -o "ControlPath=${RW_CONTROL_PATH:-/tmp/rw-exec-%C}" \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PubkeyAuthentication=yes \
    -o NumberOfPasswordPrompts=0 \
    -o "ConnectTimeout=${RW_CONNECT_TIMEOUT:-8}" \
    -o LogLevel=ERROR \
    -T \
    "$RW_SSH_TARGET" \
    "$@"
}

# A mapped root, not the whole disk and not a home directory.
mirror_safe() {
  local path="$1" side="$2"
  case "$path" in
    "" | /*) ;;
    *) mirror_die "${side} path must be absolute"; return 1 ;;
  esac
  case "$path" in
    *..*) mirror_die "${side} path must not contain .."; return 1 ;;
  esac
  case "$path" in
    / | /tmp | /private | /private/tmp | /Users | /home | /root | /var | /private/var)
      mirror_die "${side} path is too broad"
      return 1
      ;;
  esac
  if [[ -n "${HOME:-}" && ( "$path" == "$HOME" || "$path" == "$HOME"/* ) ]]; then
    mirror_die "refusing to mirror the home directory"
    return 1
  fi
  return 0
}

mirror_manifest() {
  printf '%s.rw-manifest' "$1"
}

mirror_write_manifest() {
  local local_dir="$1" manifest tmp
  manifest=$(mirror_manifest "$local_dir")
  tmp="${manifest}.tmp.$$"
  (
    cd "$local_dir" || exit 1
    find . -print | LC_ALL=C sort | sed '/^\.$/d; s|^\./||'
  ) >"$tmp"
  mv "$tmp" "$manifest"
}

# Paths present at the last pull and missing locally. Empty when no pull yet.
mirror_deletions() {
  local local_dir="$1" manifest path
  manifest=$(mirror_manifest "$local_dir")
  [[ -f "$manifest" ]] || return 0
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    if [[ ! -e "$local_dir/$path" && ! -L "$local_dir/$path" ]]; then
      printf '%s\n' "$path"
    fi
  done <"$manifest"
}

mirror_publish_local() {
  local stage="$1" dest="$2" delete_flag="$3" delete_file="$4"
  local args=()
  args=(--stage "$stage" --dest "$dest")
  if [[ "$delete_flag" == delete ]]; then
    args+=(--delete)
  fi
  if [[ -n "$delete_file" ]]; then
    args+=(--delete-list "$delete_file")
  fi
  python3 "$(mirror_src)/mirror-publish.py" "${args[@]}"
}

mirror_publish_remote() {
  local stage="$1" dest="$2" delete_file="$3"
  local remote_list="" quoted
  if [[ -n "$delete_file" ]]; then
    remote_list="/tmp/rw-mirror-del.${RANDOM}${RANDOM}"
    quoted=$(printf '%q' "$remote_list")
    mirror_ssh "cat > ${quoted}" <"$delete_file" || return 1
  fi
  mirror_ssh "python3 - --stage $(printf '%q' "$stage") --dest $(printf '%q' "$dest") ${remote_list:+--delete-list $(printf '%q' "$remote_list")}" \
    <"$(mirror_src)/mirror-publish.py"
  local rc=$?
  if [[ -n "$remote_list" ]]; then
    mirror_ssh "rm -f -- $(printf '%q' "$remote_list")" >/dev/null 2>&1 || true
  fi
  return "$rc"
}

mirror_rsync() {
  local src="$1" dest="$2"
  # Bash 3.2 with set -u rejects an empty "${extra[@]}".
  if [[ -n "${RW_MIRROR_BWLIMIT:-}" ]]; then
    rsync -a --bwlimit="$RW_MIRROR_BWLIMIT" -e "$(mirror_rsh)" -- "$src" "$dest" >/dev/null
  else
    rsync -a -e "$(mirror_rsh)" -- "$src" "$dest" >/dev/null
  fi
}

# Push one pair. Remote-only files stay. Publishing happens only after rsync.
mirror_push_one() {
  local local_dir="$1" remote_dir="$2" stage del_local remote_stage rc
  mirror_safe "$local_dir" local || return 1
  mirror_safe "$remote_dir" remote || return 1
  if [[ ! -d "$local_dir" ]]; then
    return 0
  fi
  remote_stage="/tmp/rw-mirror-stage.${RANDOM}${RANDOM}"
  mirror_ssh "rm -rf -- $(printf '%q' "$remote_stage") && mkdir -p -- $(printf '%q' "$remote_dir") $(printf '%q' "$remote_stage")" \
    || return 1
  del_local=$(mktemp "${TMPDIR:-/tmp}/rw-mirror-del.XXXXXX")
  mirror_deletions "$local_dir" >"$del_local" || true
  if ! mirror_rsync "${local_dir}/" "${RW_SSH_TARGET}:${remote_stage}/"; then
    rc=$?
    rm -f "$del_local"
    mirror_ssh "rm -rf -- $(printf '%q' "$remote_stage")" >/dev/null 2>&1 || true
    return "$rc"
  fi
  if [[ -s "$del_local" ]]; then
    mirror_publish_remote "$remote_stage" "$remote_dir" "$del_local"
  else
    mirror_publish_remote "$remote_stage" "$remote_dir" ""
  fi
  rc=$?
  rm -f "$del_local"
  mirror_ssh "rm -rf -- $(printf '%q' "$remote_stage")" >/dev/null 2>&1 || true
  [[ "$rc" -eq 0 ]] || return "$rc"
  # Remember files this push placed, so a later local delete is removable.
  mirror_write_manifest "$local_dir"
}

# Pull one pair. The local mirror changes only after rsync exits 0.
mirror_pull_one() {
  local local_dir="$1" remote_dir="$2" stage rc
  mirror_safe "$local_dir" local || return 1
  mirror_safe "$remote_dir" remote || return 1
  mkdir -p "$local_dir"
  mirror_ssh "mkdir -p -- $(printf '%q' "$remote_dir")" || return 1
  stage=$(mktemp -d "${TMPDIR:-/tmp}/rw-mirror-pull.XXXXXX")
  if ! mirror_rsync "${RW_SSH_TARGET}:${remote_dir}/" "${stage}/"; then
    rc=$?
    rm -rf "$stage"
    return "$rc"
  fi
  mirror_publish_local "$stage" "$local_dir" delete ""
  rc=$?
  rm -rf "$stage"
  [[ "$rc" -eq 0 ]] || return "$rc"
  mirror_write_manifest "$local_dir"
}

mirror_each() {
  local op="$1" i n
  [[ -n "${RW_SSH_TARGET:-}" ]] || {
    mirror_die "RW_SSH_TARGET is unset"
    return 1
  }
  path_map_load
  n=${#PM_LOCAL[@]}
  [[ "$n" -gt 0 ]] || return 0
  for ((i = 0; i < n; i++)); do
    if [[ "$op" == push ]]; then
      mirror_push_one "${PM_LOCAL[$i]}" "${PM_REMOTE[$i]}" || return 1
    else
      mirror_pull_one "${PM_LOCAL[$i]}" "${PM_REMOTE[$i]}" || return 1
    fi
  done
}

mirror_push() {
  mirror_each push
}

mirror_pull() {
  mirror_each pull
}
