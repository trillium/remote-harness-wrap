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

## What unsupported means

`unsupported` is a measured result, not a skipped test.
The claim was tried, ordinary processes could not do it, and the log under `evidence/` records the reason.
On the provider Mac, B1 is unsupported for a live mount.
An NFS mount can be created, and an ordinary read of that mount returns errno 1.
System Policy denies the read.
SMB and a FUSE-T sshfs mount are denied the same way: `file-read-data` returns errno 1, including for the harness.
The supported route is a mirror inside `RW_PATH_MAP`.
After each wrapped command, `src/rw-bash` pulls the remote tree into the local directory.
Before the next command, it pushes files the provider wrote or edited.
Read, write, edit, glob, and search use that directory.
They do not read a mount.
Commands still run on the remote when the harness uses `src/rw-bash` or the DYLD forwarder in `src/forwarder-mac.c`.
The `src/rg` wrapper still searches on the remote when the working directory is inside `RW_PATH_MAP`.

## File plane

The supported file route is the rsync barrier in `src/mirror.sh`.
`src/rw run` pulls the remote project into `--local` before the harness starts.
`src/rw-bash` pushes provider writes to the remote before each command and pulls the remote tree back after it.
A transfer lands in a staging directory. Each destination path is replaced only after that copy is complete, so a dropped link leaves the previous file or no file.
The mirror stays inside `RW_PATH_MAP`.

`src/rw sync` still copies one scratch directory with tar over ssh.
The remote directory must be `/tmp/rw-bd-*` or `/tmp/rw-pkg-*`.
`push` replaces the remote directory.
`pull` replaces the local directory.
That copy is the plane measured by B2 through B9.
It is not a live mount, and it does not make B1 true.
`src/rw run` starts a command with the path map set.
A command named `claude` gets `CLAUDE_CODE_SHELL`.
Any other command gets the DYLD forwarder.
`src/rw down` stops that session and removes the scratch directory that `run` created.

Run the proofs for one ssh target:

```
RW_SSH_TARGET=<ssh-host> RW_LABEL=remote-linux tests/file-plane/run.sh
```

B1 measures the provider, not a remote:

```
tests/file-plane/b1.sh
```

The same command is the setup on a Mac peer.
Use a label, not a hostname:

```
RW_SSH_TARGET=<ssh-host> RW_LABEL=remote-mac tests/file-plane/run.sh
```

On a peer whose operator ssh accepts auth method none, that answer is the tailnet identity already accepted for this operator.
It is not an anonymous export, and a second key is not the client boundary there.
The client boundary for a revocable run is `src/run-sshd.sh`.
That listener allows one public key and refuses a session with no key.
The operator endpoint is left unchanged.

Logs go in `evidence/file-plane/`.
The runner removes its scratch directories.

## Interception

Proofs for the DYLD forwarder are under `tests/interception/`.
Logs go in `evidence/interception/`.
D4 stays unproven when no virtual machine is required, because guest memory is not measured.
D5 runs the group C sessions while no guest is running.
The forwarder runs on the provider in that same state.

```
RW_SSH_TARGET=<ssh-host> RW_LABEL=provider-mac tests/interception/d5.sh
```

## Wrapping another harness

`docs/wrap-a-harness.md` is the procedure.
`tests/coverage/c9.sh <command-name>...` runs its automatic steps.

## Two sessions on two remotes

```
tests/whole/f6.sh --target-a <ssh-host> --target-b <ssh-host>
```

Each session gets its own path map, broker directory and ssh control socket.
The log is `evidence/whole/f6.log`.
