#!/bin/bash
# Run a remote command over ssh and return the remote command's own exit
# status, whatever the ssh server reports.
#
# Some ssh servers (the Tailscale SSH server on a tailnet host) answer every
# command with exit status 0. A test that trusts the status of `ssh host cmd`
# then passes when cmd failed. The status is therefore carried in the output:
# the remote side runs the command in a subshell and writes a marker line with
# the status to stderr. This helper strips that line and returns its number.
#
#   rw_ssh_inband <ssh words ending with the target> -- <remote command words>
#
# stdout and stdin pass through untouched. stderr is replayed without the
# marker. If no marker arrives the remote command never finished (connection
# failed, killed): the ssh status is returned, or 255 when ssh claimed 0.
rw_ssh_inband() {
  local -a sshcmd=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    sshcmd+=("$1")
    shift
  done
  [[ "${1:-}" == -- ]] && shift
  local marker="__RW_STATUS_${RANDOM}${RANDOM}${RANDOM}__"
  local errf rc status=""
  errf=$(mktemp "${TMPDIR:-/tmp}/rw-inband.XXXXXX") || return 255
  # A newline after the command ends a trailing comment and keeps a heredoc
  # body for `bash -s` intact; the subshell survives an `exit` in the command.
  "${sshcmd[@]}" "( $*
); __rw_rc=\$?; printf '\\n${marker}%s\\n' \"\$__rw_rc\" >&2; exit \"\$__rw_rc\"" 2>"$errf"
  rc=$?
  local content before rest
  content=$(cat "$errf"; printf x)
  content=${content%x}
  rm -f "$errf"
  if [[ "$content" == *"$marker"* ]]; then
    before=${content%%"$marker"*}
    before=${before%$'\n'} # the newline the remote added in front of the marker
    rest=${content#*"$marker"}
    status=${rest%%$'\n'*}
    printf '%s' "$before" >&2
  else
    printf '%s' "$content" >&2
  fi
  if [[ "$status" =~ ^[0-9]+$ ]]; then
    return "$status"
  fi
  [[ "$rc" -ne 0 ]] && return "$rc"
  return 255
}
