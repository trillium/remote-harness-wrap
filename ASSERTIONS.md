# Assertions

The system is functional when every assertion marked **required** is proven. Each is a claim with a test that can fail. "Provider" is the machine running the harness. "Remote" is the machine where work must land.

Status: `unproven` (no evidence), `partial` (shown in a narrow case, noted), `proven` (evidence recorded), `unsupported` (shown not possible, documented).

A status below is proven, partial, or unsupported only when the named log shows that result.

## A. Exec plane: commands run on the remote

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| A1 | The harness accepts a wrapper as its shell and calls it with its normal arguments. | Log the wrapper's argv during a real harness session. | yes | proven (evidence/exec/local-a1.log) |
| A2 | A command's stdout, stderr and exit code reach the harness unchanged. | Run commands that print to both streams and exit 0, 1 and 7; compare with a local run. | yes | proven (evidence/exec/) |
| A3 | The harness's working directory follows `cd` across calls. | `cd sub` in one call, `pwd` in the next. The harness shows the mapped local path. | yes | proven (evidence/exec/) |
| A4 | The harness's shell snapshot or startup file is applied remotely without copying secrets it should not. | Snapshot with a canary secret: the canary does not appear on the remote. | yes | proven (evidence/exec/) |
| A5 | Absolute paths in commands are rewritten between provider and remote forms, in both directions. | Command mentions a provider path; the remote sees the remote path; output paths come back mapped. | yes | proven (evidence/exec/) |
| A6 | A background process started by a command survives after the command returns. | Start a server with `&`, return, reach it in a later call. | yes | proven (evidence/exec/) |
| A7 | Cancelling or timing out a command kills the remote process, not just the local one. | Start `sleep 600`, interrupt, check the remote process list. | yes | proven (evidence/exec/) |
| A8 | Parallel commands do not interfere. | 20 concurrent commands with distinct outputs; each returns its own. | yes | proven (evidence/exec/) |
| A9 | If the remote is unreachable the command fails loudly. It never runs locally by accident. | Block the network; expect a clear error and no local side effect. | yes | proven (evidence/exec/) |
| A10 | Per-command overhead is bounded. | Median added latency over 100 trivial commands is under 300 ms after the first. | no | unproven |
| A11 | A command that needs a terminal fails clearly or works, and the behavior is documented. | Run an interactive prompt. | no | unproven |

## B. File plane: files are the remote's files

B2 to B9 were measured by copying one scratch directory with tar over ssh.
That copy is not a live mount.

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| B1 | The remote project tree is readable and writable by ordinary unprivileged processes on the provider. | `ls`, `cat`, write a file, without special permissions, on the provider OS in use. | yes | unsupported (evidence/file-plane/provider-mac-b1.log) |
| B2 | A file written by the harness's write or edit tool is visible to a remote command immediately. | Write on the provider, `cat` on the remote in the next call. | yes | proven (evidence/file-plane/) |
| B3 | A file created by a remote command is visible to the harness's file tools immediately. | Create on the remote, then read and list on the provider, 50 times, zero misses. | yes | proven (evidence/file-plane/) |
| B4 | Content search over the mount returns correct and current results, with and without memory-mapped reads. | Search for a fresh token 50 times in both modes. | yes | proven (evidence/file-plane/) |
| B5 | Directory listing and glob match the remote exactly, including new, renamed and deleted entries. | Mutate on the remote, list on the provider, compare. | yes | proven (evidence/file-plane/) |
| B6 | File modes, symlinks, case-sensitive names, unicode names, large files and version-control operations behave correctly. | Run a version-control status, commit and checkout through the mount. | yes | proven (evidence/file-plane/) |
| B7 | The export is limited to one client, one directory, and no root access. | Attempt access from another client and from outside the directory; both fail. | yes | partial (remote-linux accepts auth method none, so a second key is not a client boundary; remote-mac refuses a second key; evidence/file-plane/) |
| B8 | Dropping the network gives errors, not a hung harness. | Cut the link mid-read; the call fails within a bounded time. | yes | proven (evidence/file-plane/) |
| B9 | Unmounting and teardown leave nothing mounted, exported or running. | Check mounts, exports and processes afterward. | yes | proven (evidence/file-plane/) |

## C. Harness coverage: each tool proven in a real session

Each row needs one real session where the harness, unmodified, performs the action and an independent observation shows it happened on the remote (a hostname, a marker file only the remote has).

| ID | Assertion | Req | Status |
| --- | --- | --- | --- |
| C1 | Claude Code: shell tool runs on the remote. | yes | unproven |
| C2 | Claude Code: read, write, edit change remote files. | yes | unproven |
| C3 | Claude Code: glob and search see remote files. | yes | unproven |
| C4 | Claude Code: the separate persistent shell tool, hooks and local tool servers are either remote or documented as local. | no | unproven |
| C5 | OpenCode: shell tool runs on the remote. | yes | partial (one free-model turn, command forwarded from a Linux guest) |
| C6 | OpenCode: file tools see remote files. | yes | unproven |
| C7 | Codex: shell and file tools. | no | unproven |
| C8 | Grok: shell and file tools, or documented unsupported with the reason. | no | unproven |
| C9 | Any other harness: a documented procedure to test whether it can be wrapped (dynamic or static binary, signed or not, shell setting). | no | unproven |

## D. Interception without changing the harness

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| D1 | For harnesses that cannot name their shell, command execution is forwarded by interception. | Preload a forwarder; a command prints the remote hostname. | yes | proven (evidence/interception/) |
| D2 | The forwarder never forwards itself, the transport, or the dynamic linker. | Process list shows no recursion. | yes | proven (evidence/interception/) |
| D3 | Signed, hardened or statically linked harness binaries are classified, with the supported route for each. | Table of binaries and results. | yes | proven (evidence/interception/provider-mac-d3.log) |
| D4 | If a virtual machine is required, its memory use is measured and bounded. | Resident memory under 1 GiB while idle and while running a task. | no | unproven (no guest was required, so memory was not measured; evidence/interception/provider-mac-d4.log) |
| D5 | The no-virtual-machine route is exercised for every harness where it is possible. | Same C-series tests with no guest running. | yes | partial (forwarder ran with no guest; group C sessions were not part of this proof; evidence/interception/provider-mac-d5.log) |

## E. Security and secrets

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| E1 | Harness credentials stay on the provider and are never copied to the remote. | Search the remote filesystem and process environment for the token after a session. | yes | unproven |
| E2 | Provider secrets in shell startup files do not reach the remote unless allowed. | Canary secret in a startup file (see A4). | yes | unproven |
| E3 | Transport is key-authenticated and limited to the private network. | Attempt a password login and a public-interface connection; both refused. | yes | unproven |
| E4 | Logs never contain tokens or file contents. | Scan logs after a session. | yes | unproven |
| E5 | A run can be fully revoked: keys, exports and mounts removed. | Teardown script followed by an access test. | yes | unproven |

## F. Whole system

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| F1 | One command starts a wrapped session for a chosen harness, remote and project; one command stops it and cleans up. | Run both on a clean machine. | yes | unproven |
| F2 | End to end: an unmodified harness fixes a failing test in a repository that exists only on the remote. The tests run on the remote, the commit lands on the remote, and nothing of the project is left on the provider. | The failing test passes on the remote; the provider has no copy. | yes | unproven |
| F3 | The harness was not modified, patched or re-signed. | Checksum of the harness binary before and after. | yes | unproven |
| F4 | A dropped connection mid-task recovers or fails clearly, with no corrupted files. | Kill the link during a write; verify the file is whole or absent. | yes | unproven |
| F5 | The setup reproduces from the repository's instructions on a second pair of machines. | A fresh operator follows the steps. | yes | unproven |
| F6 | Two sessions can use different remotes at once. | Two harnesses, two remotes, no cross-talk. | no | unproven |

## Order of proof

1. B1 and B2 first: without a readable remote file plane the file tools cannot go remote on that OS. This decides the design.
2. A1 to A9 in a real Claude session (C1) using the shell wrapper.
3. C2 and C3 once B passes.
4. D1 to D5 for harnesses the wrapper cannot reach.
5. E, then F1 to F5.

A required assertion that is shown impossible moves to `unsupported`, and the README states what that means for users.
