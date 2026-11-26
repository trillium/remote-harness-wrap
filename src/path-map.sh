#!/bin/bash
# Path map used by src/rw and src/rg.
# RW_PATH_MAP is a list of local|remote pairs separated by ';' or newlines.
# The longest matching prefix wins. A trailing slash is removed.
# "/" is not a prefix. /tmp and /private/tmp match each other.
# src/rw-bash reads the same pair format.

path_map_reset() {
  PM_LOCAL=()
  PM_REMOTE=()
}

path_map_load() {
  local map="${RW_PATH_MAP:-}" pair pre rem
  path_map_reset
  map=${map//$'\n'/;}
  local IFS=';'
  # shellcheck disable=SC2086
  for pair in $map; do
    [[ -z "$pair" || "$pair" != *'|'* ]] && continue
    pre="${pair%%|*}"
    rem="${pair#*|}"
    [[ "$pre" != "/" ]] && pre="${pre%/}"
    [[ "$rem" != "/" ]] && rem="${rem%/}"
    PM_LOCAL+=("$pre")
    PM_REMOTE+=("$rem")
  done
}

path_map_aliases() {
  local p="$1"
  printf '%s\n' "$p"
  case "$p" in
    /private/tmp | /private/tmp/*) printf '%s\n' "/tmp${p#/private/tmp}" ;;
    /tmp | /tmp/*) printf '%s\n' "/private/tmp${p#/tmp}" ;;
    /private/var/folders/*) printf '%s\n' "/var/folders${p#/private/var/folders}" ;;
    /var/folders/*) printf '%s\n' "/private/var/folders${p#/var/folders}" ;;
  esac
}

# Print the unmatched suffix when p is pre or a child of pre.
# Return 1 when it does not match.
path_map_suffix() {
  local p="$1" pre="$2" pa prea
  while IFS= read -r pa; do
    [[ -n "$pa" ]] || continue
    while IFS= read -r prea; do
      [[ -n "$prea" ]] || continue
      if [[ "$pa" == "$prea" ]]; then
        printf '\n'
        return 0
      fi
      if [[ "$pa" == "$prea"/* ]]; then
        printf '%s\n' "${pa#"$prea"}"
        return 0
      fi
    done < <(path_map_aliases "$pre")
  done < <(path_map_aliases "$p")
  return 1
}

path_map_translate() {
  local p="$1" direction="$2"
  local i best=-1 bestlen=-1 n pre suf
  if [[ "$direction" == remote ]]; then
    n=${#PM_LOCAL[@]}
  else
    n=${#PM_REMOTE[@]}
  fi
  if [[ $n -eq 0 ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  for ((i = 0; i < n; i++)); do
    if [[ "$direction" == remote ]]; then
      pre="${PM_LOCAL[$i]}"
    else
      pre="${PM_REMOTE[$i]}"
    fi
    if path_map_suffix "$p" "$pre" >/dev/null; then
      if [[ ${#pre} -gt $bestlen ]]; then
        bestlen=${#pre}
        best=$i
      fi
    fi
  done
  if [[ $best -ge 0 ]]; then
    if [[ "$direction" == remote ]]; then
      suf=$(path_map_suffix "$p" "${PM_LOCAL[$best]}")
      printf '%s%s\n' "${PM_REMOTE[$best]}" "$suf"
    else
      suf=$(path_map_suffix "$p" "${PM_REMOTE[$best]}")
      printf '%s%s\n' "${PM_LOCAL[$best]}" "$suf"
    fi
  else
    printf '%s\n' "$p"
  fi
}

path_map_to_remote() {
  path_map_translate "$1" remote
}

path_map_to_local() {
  path_map_translate "$1" local
}
