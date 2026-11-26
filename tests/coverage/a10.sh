#!/bin/bash
# A10. Median added latency of 100 trivial commands after the first is under 300 ms.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=common.sh
. "$HERE/common.sh"
coverage_begin "$@"

proj="${RW_LOCAL_ROOT}/proj"
meas="${RW_RAW}/a10-measure.txt"
mkdir -p "$proj"
# One command installs the broker. The measured series starts after it.
exec_wrapper "$proj" "true" >/dev/null

python3 - "$RW_WRAP" "$proj" "$meas" <<'PY'
import os, statistics, subprocess, sys
wrap, cwd, dest = sys.argv[1:]
env = os.environ.copy()
def series(cmd, n):
    out = []
    for _ in range(n):
        t0 = __import__("time").perf_counter()
        subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        out.append((__import__("time").perf_counter() - t0) * 1000.0)
    return out
wrap_ms = series([wrap, "-c", "true"], 101)
local_ms = series(["/bin/bash", "-c", "true"], 101)
added = [wrap_ms[i] - local_ms[i] for i in range(1, 101)]
med = statistics.median(added)
lines = [
    f"warmup_ms: {wrap_ms[0]:.1f}",
    f"median_added_ms: {med:.1f}",
    f"median_wrapper_ms: {statistics.median(wrap_ms[1:]):.1f}",
    f"median_local_ms: {statistics.median(local_ms[1:]):.1f}",
    f"samples: 100",
    f"bound_ms: 300",
]
open(dest, "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if med < 300 else 2)
PY
rc=$?
if [[ -f "$meas" ]]; then
  while IFS= read -r line; do
    note "$line"
  done <"$meas"
fi
if [[ "$rc" -eq 0 ]]; then
  pass "median added latency is under 300 ms"
else
  fail "median added latency is not under 300 ms"
fi
note "RESULT: see passes"
coverage_finish a10
