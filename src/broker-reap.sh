#!/bin/bash
# Remote side of `rw-bash --reap`, `rw run` exit and `rw down`. Sent over ssh
# on stdin: bash -s -- <broker-root>
#
# Stops the broker for one root, any job it started, and removes the root.
# It acts only on a directory that holds a broker.sh, and signals the broker
# pid only when that pid's command line names this root's broker.sh.
set -u
root="${1:-}"
case "$root" in
  /*/*) ;;
  *) echo "reap: refusing root '$root'" >&2; exit 2 ;;
esac
case "$root" in
  *..*) echo "reap: refusing root '$root'" >&2; exit 2 ;;
esac
[[ -f "$root/broker.sh" ]] || exit 0
pid=$(cat "$root/broker.pid" 2>/dev/null | tr -cd '0-9')
for jp in "$root"/jobs/*/pid; do
  [[ -f "$jp" ]] || continue
  j=$(tr -cd '0-9' <"$jp")
  [[ -n "$j" ]] || continue
  kill -TERM -- "-$j" 2>/dev/null || kill -TERM "$j" 2>/dev/null || true
done
if [[ -n "$pid" ]] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$root/broker.sh"; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
fi
rm -rf -- "$root"
exit 0
