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

## What unsupported means

`unsupported` is a measured result, not a skipped test.
The claim was tried, ordinary processes could not do it, and the log under `evidence/` records the reason.
On the provider Mac, B1 is unsupported.
An NFS mount can be created, and an ordinary read of that mount returns errno 1.
System Policy denies the read.
SMB port 445 was closed on the probed hosts, and FUSE-T was not installed.
The FUSE-T installer needs an administrator, so it was not installed for this proof.
File tools in the harness (read, write, edit, glob) see the provider copy only.
They do not see the remote tree through a mount.
Commands still run on the remote when the harness uses `src/rw-bash` or the DYLD forwarder in `src/forwarder-mac.c`.
A search uses `src/rg`, which runs on the remote when the working directory is inside `RW_PATH_MAP`.

## File plane

`src/rw sync` copies one scratch directory with tar over ssh.
The remote directory must be `/tmp/rw-bd-*` or `/tmp/rw-pkg-*`.
`push` replaces the remote directory.
`pull` replaces the local directory.
This copy is the plane measured by B2 through B9.
It is not a live mount, and it does not make B1 true.
`src/rw run` starts a command with the path map set.
A command named `claude` gets `CLAUDE_CODE_SHELL`.
Any other command gets the DYLD forwarder.
`src/rw down` removes the scratch directory that `run` created.

Run the proofs for one ssh target:

```
RW_SSH_TARGET=<ssh-host> RW_LABEL=remote-linux tests/file-plane/run.sh
```

B1 measures the provider, not a remote:

```
tests/file-plane/b1.sh
```

Logs go in `evidence/file-plane/`.
The runner removes its scratch directories.

## Interception

Proofs for the DYLD forwarder are under `tests/interception/`.
Logs go in `evidence/interception/`.
D4 stays unproven when no virtual machine is required, because guest memory is not measured.
D5 records a partial result: the forwarder runs with no guest, and the group C harness sessions are out of scope.
