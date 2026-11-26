# remote-harness-wrap

Run an unmodified AI coding harness (Claude Code, OpenCode, Codex, others) on one machine while every command it runs and every file it touches lands on another machine. The harness is not patched and does not know.

This repository starts with `ASSERTIONS.md`: the list of claims that must each be proven, with evidence, before the whole system counts as working. Nothing is built until its assertion is written down here.

Rules for this repository:

- An assertion is proven only by an observable result recorded under `evidence/`, never by reading code.
- A harness that cannot be proven is listed as unsupported, not omitted.
- No credentials, hostnames or account names are committed.

## Exec plane

`src/rw-bash` is the shell a harness execs.
Point `CLAUDE_CODE_SHELL` at that file.
The path contains `bash`, which is the name test the harness uses.

Run the proofs for one target:

```
RW_SSH_TARGET=localhost tests/exec/run.sh
```

`RW_PATH_MAP` is a list of `local|remote` pairs separated by semicolons.
When it is unset, the runner creates scratch directories and removes them.
Each assertion is also a script under `tests/exec/`.
Logs from a run go in `evidence/exec/`.
A real harness session reads its credential path from `RW_TOKEN_FILE` and does not print that file.

Harness coverage that needs only the exec plane is `tests/coverage/run.sh`.
Those logs go in `evidence/coverage/`.
Set `RW_TOKEN_FILE` to the account the Claude session should use.
The runner does not print that file.
