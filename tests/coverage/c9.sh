#!/bin/bash
# C9. A repeatable procedure that says how an arbitrary harness could be wrapped.
# The steps are written in docs/wrap-a-harness.md. This script runs the
# automatic ones (steps 1 to 4) on this Mac for each harness named.
#
#   tests/coverage/c9.sh claude opencode codex grok pi goose
#
# Each argument is a command name found on PATH. The verdict is the route the
# procedure indicates. Step 5 (a live session that shows the command ran on the
# remote) needs a working model account and is recorded by the C1 to C8 logs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../interception/lib.sh
. "$HERE/../interception/lib.sh"
RW_LABEL="${RW_LABEL:-provider-mac}"
RW_EVIDENCE="$(cd "$HERE/../.." && pwd)/evidence/coverage"
intercept_begin "$@"
intercept_build
note "route: procedure"
names=("${PROOF_REST[@]}")
if [[ ${#names[@]} -eq 0 ]]; then
  names=(claude opencode codex grok pi goose)
fi

# Step 1: what is the file, and if it is a script, what runs it.
resolve_real() {
  local path="$1" first interp
  if file "$path" | grep -q 'Mach-O'; then
    printf '%s' "$path"
    return 0
  fi
  # A shell launcher that ends in `exec <binary>` stands for that binary.
  interp=$(awk '/^[[:space:]]*exec[[:space:]]/ {sub(/^[[:space:]]*exec[[:space:]]+/, ""); gsub(/"/, ""); print $1; exit}' "$path" 2>/dev/null || true)
  interp=${interp/#\~/$HOME}
  interp=${interp//\$HOME/$HOME}
  if [[ -n "$interp" && -f "$interp" ]]; then
    interp=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$interp")
    if file "$interp" | grep -q 'Mach-O'; then
      printf '%s' "$interp"
      return 0
    fi
  fi
  first=$(head -1 "$path" 2>/dev/null || true)
  case "$first" in
    '#!'*)
      interp=${first#\#!}
      case "$interp" in
        */env\ *) interp=$(command -v "$(printf '%s' "$interp" | awk '{print $2}')" || true) ;;
        *) interp=${interp%% *} ;;
      esac
      if [[ -n "$interp" && -e "$interp" ]]; then
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$interp"
        return 0
      fi
      ;;
  esac
  printf '%s' "$path"
}

procedure_one() {
  local name="$1" path real kind link flags hints log loaded child ticks route
  path=$(command -v "$name" || true)
  if [[ -z "$path" ]]; then
    note "harness=$name present=no"
    pass "$name is absent, so it is listed as not tested"
    return 0
  fi
  real=$(resolve_real "$path")
  if file "$path" | grep -q 'script' && file "$real" | grep -q 'Mach-O' && [[ "$real" != "$path" ]]; then
    kind="script-then-$(basename "$real")"
  elif file "$path" | grep -q 'script'; then
    kind="script-run-by-$(basename "$real")"
  elif file "$real" | grep -q 'Mach-O'; then
    kind=mach-o
  else
    kind=other
  fi
  # Step 2: dynamic or static, signed or not.
  if otool -L "$real" 2>/dev/null | tail -n +2 | grep -q .; then
    link=dynamic
  else
    link=static
  fi
  flags=$(codesign -d --verbose=2 "$real" 2>&1 | awk -F'flags=' '/flags=/{print $2; exit}' || true)
  flags=${flags%% *}
  # Step 3: does the file name a shell setting.
  hints=$(strings -a "$path" "$real" 2>/dev/null | grep -o -E '\b[A-Z][A-Z0-9_]*_SHELL\b' | sort -u | tr '\n' ',' | sed 's/,$//' || true)
  # Step 4: does the forwarder load into the real binary.
  log="$RW_RAW/c9-${name}.log"
  : >"$log"
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
  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  if grep -q 'decision=loaded' "$log"; then
    loaded=yes
  else
    loaded=no
  fi
  # Verdict. A named shell setting is the first route to try.
  if [[ "$hints" == *CLAUDE_CODE_SHELL* ]]; then
    route=shell-setting
  elif [[ "$loaded" == yes ]]; then
    route=dyld
  elif [[ "$link" == static ]]; then
    route=no-interception
  else
    case "$flags" in
      *runtime*) route=no-interception ;;
      *) route=not-observed ;;
    esac
  fi
  note "harness=$name kind=$kind link=$link signing=${flags:-none} shell_names=${hints:-none} dyld_loaded=$loaded route=$route"
  pass "$name classified as $route"
}

for n in "${names[@]}"; do
  procedure_one "$n"
done
note "assertion_status: procedure written and run; a live session is still needed per harness (step 5)"
proof_finish c9
