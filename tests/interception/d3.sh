#!/bin/bash
# D3. Classify signed, hardened, and ad-hoc harness binaries on this Mac.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"
RW_LABEL="${RW_LABEL:-provider-mac}"
intercept_begin "$@"
intercept_build
note "route: classify"

classify_one() {
  local name="$1" path="$2" kind flags loaded route real
  if [[ -z "$path" || ! -e "$path" ]]; then
    note "binary=$name present=no"
    pass "$name is absent"
    return 0
  fi
  real=$(python3 -c '
import os, sys
path = sys.argv[1]
raw = open(path, "rb").read(4)
macho = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe")
if raw in macho:
    print(path)
    raise SystemExit(0)
text = open(path, "r", errors="replace").read().splitlines()
target = ""
for line in text:
    line = line.strip()
    if line.startswith("exec "):
        rest = line[5:].strip()
        if rest.startswith("\""):
            target = rest.split("\"", 2)[1]
        else:
            target = rest.split()[0]
        break
target = os.path.expanduser(os.path.expandvars(target))
if target and os.path.isfile(target):
    print(os.path.realpath(target))
else:
    print(path)
' "$path")
  if file "$real" | grep -q 'Mach-O'; then
    kind=mach-o
  elif file "$path" | grep -q 'script'; then
    kind=script
  else
    kind=other
  fi
  flags=$(codesign -d --verbose=2 "$real" 2>&1 | awk -F'flags=' '/flags=/{print $2; exit}' || true)
  flags=${flags%% *}
  log="$RW_RAW/d3-${name}.log"
  : >"$log"
  # Launch directly. A platform binary such as /usr/bin/perl strips DYLD_*
  # before exec, which would hide a load that the binary itself allows.
  DYLD_INSERT_LIBRARIES="$RW_DYLIB" \
    RW_LOG="$log" \
    RW_SSH_TARGET=localhost \
    RW_ENV_MODE=reduced \
    "$real" --version >/dev/null 2>&1 &
  child=$!
  ticks=0
  while kill -0 "$child" 2>/dev/null && [[ $ticks -lt 20 ]]; do
    sleep 1
    ticks=$((ticks + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
  if grep -q 'decision=loaded' "$log"; then
    loaded=yes
  else
    loaded=no
  fi
  route=unclassified
  case "$flags" in
    *runtime*)
      if [[ "$name" == claude ]]; then
        route=CLAUDE_CODE_SHELL
      else
        route=no-interception
      fi
      ;;
    *adhoc* | *linker-signed*)
      if [[ "$loaded" == yes ]]; then
        route=dyld
      else
        route=dyld-not-observed
      fi
      ;;
    *)
      if [[ "$loaded" == yes ]]; then
        route=dyld
      elif [[ "$kind" == script && "$loaded" == no ]]; then
        route=unwrap-then-dyld
      else
        route=no-interception
      fi
      ;;
  esac
  if [[ "$kind" == script && "$loaded" == yes ]]; then
    route=unwrap-then-dyld
  fi
  note "binary=$name kind=$kind flags=${flags:-none} dyld_loaded=$loaded route=$route"
  if [[ "$route" == unclassified ]]; then
    fail "$name was not classified"
  else
    pass "$name classified as $route"
  fi
}

classify_one claude "$(command -v claude || true)"
classify_one opencode "$(command -v opencode || true)"
classify_one codex "$(command -v codex || true)"
classify_one grok "$(command -v grok || true)"
if [[ "$FAILS" -eq 0 ]]; then
  note "assertion_status: proven"
else
  note "assertion_status: partial"
fi
proof_finish d3
