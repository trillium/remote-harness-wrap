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
| A10 | Per-command overhead is bounded. | Median added latency over 100 trivial commands is under 300 ms after the first. | no | proven (evidence/coverage/a10.log, median added 299.5 ms) |
| A11 | A command that needs a terminal fails clearly or works, and the behavior is documented. | Run an interactive prompt. | no | proven (evidence/coverage/a11.log). No remote tty. read exits 1. Input is not forwarded. |

## B. File plane: files are the remote's files

B2 to B9 were measured by copying one scratch directory with tar over ssh.
That copy is not a live mount.

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| B1 | The remote project tree is readable and writable by ordinary unprivileged processes on the provider. | `ls`, `cat`, write a file, without special permissions, on the provider OS in use. | yes | proven (evidence/file-plane/provider-mac-b1-webdav.log). On a Mac provider, `mount_webdav` of a loopback ssh forward to a Linux remote's WebDAV server ran as the ordinary user. An ordinary python3 listed, read and wrote the remote tree, and each side saw the other's writes. The mount is `noexec`. NFS stays unreadable (evidence/file-plane/provider-mac-b1.log), FUSE-T needs an administrator, and SMB was not probed. Only the Linux remote was tried. |
| B2 | A file written by the harness's write or edit tool is visible to a remote command immediately. | Write on the provider, `cat` on the remote in the next call. | yes | proven (evidence/file-plane/) |
| B3 | A file created by a remote command is visible to the harness's file tools immediately. | Create on the remote, then read and list on the provider, 50 times, zero misses. | yes | proven (evidence/file-plane/) |
| B4 | Content search over the mount returns correct and current results, with and without memory-mapped reads. | Search for a fresh token 50 times in both modes. | yes | proven (evidence/file-plane/) |
| B5 | Directory listing and glob match the remote exactly, including new, renamed and deleted entries. | Mutate on the remote, list on the provider, compare. | yes | proven (evidence/file-plane/) |
| B6 | File modes, symlinks, case-sensitive names, unicode names, large files and version-control operations behave correctly. | Run a version-control status, commit and checkout through the mount. | yes | proven (evidence/file-plane/) |
| B7 | The export is limited to one client, one directory, and no root access. | Attempt access from another client and from outside the directory; both fail. | yes | proven (evidence/file-plane/). The Linux operator endpoint answers auth method none because the tailnet identity is already accepted, so a second key is not that boundary. The run listener refuses auth method none and a second key. Both peers keep the mirror in one scratch directory and the remote uid is not root. |
| B8 | Dropping the network gives errors, not a hung harness. | Cut the link mid-read; the call fails within a bounded time. | yes | proven (evidence/file-plane/) |
| B9 | Unmounting and teardown leave nothing mounted, exported or running. | Check mounts, exports and processes afterward. | yes | proven (evidence/file-plane/) |

## C. Harness coverage: each tool proven in a real session

Each row needs one real session where the harness, unmodified, performs the action and an independent observation shows it happened on the remote (a hostname, a marker file only the remote has).

| ID | Assertion | Req | Status |
| --- | --- | --- | --- |
| C1 | Claude Code: shell tool runs on the remote. | yes | proven (evidence/coverage/c1.log). The logged-in account's Bash turn printed the remote hostname and the remote-only marker. The mirror then pulled that marker back. The SessionStart hook ran on the provider. MCP did not start. |
| C2 | Claude Code: read, write, edit change remote files. | yes | proven (evidence/coverage/c2.log). Read returned a token the remote command wrote, and the edited file was on the remote. |
| C3 | Claude Code: glob and search see remote files. | yes | proven (evidence/coverage/c3.log). Glob and search returned the file the remote command wrote. |
| C4 | Claude Code: the separate persistent shell tool, hooks and local tool servers are either remote or documented as local. | no | proven (evidence/coverage/c4.log). One Claude session on the pinned account ran against a Linux remote. A `cd sub` in one Bash call was still in effect in the next, and both calls printed the remote host name and read the remote-only file. The PreToolUse hook ran on the provider for every Bash call. A local MCP server started and answered a tool call on the provider, so hooks and tool servers are local by design. Read, write, edit, glob and search are covered by C1 to C3. |
| C5 | OpenCode: shell tool runs on the remote. | yes | proven (evidence/coverage/c5.log). Free-model shell printed the remote hostname and a remote-only marker. |
| C6 | OpenCode: file tools see remote files. | yes | proven (evidence/coverage/c6.log). Read returned a token the remote command wrote, and the written file was on the remote. |
| C7 | Codex: shell and file tools. | no | partial (evidence/coverage/c7.log). Codex was run again and still stops on its usage limit before issuing a tool. Shell and file tools were not issued. rw-bash -lc forwards. |
| C8 | Grok: shell and file tools, or documented unsupported with the reason. | no | unsupported (evidence/coverage/c8.log). The command ran in the in-process static shell on the provider. GROK_SHELL was not executed. |
| C9 | Any other harness: a documented procedure to test whether it can be wrapped (dynamic or static binary, signed or not, shell setting). | no | proven (docs/wrap-a-harness.md, evidence/coverage/provider-mac-c9.log). The procedure is written and its automatic steps ran on six harnesses. They reproduced the D3 and C8 routes for Claude Code, OpenCode, Codex and Grok. Pi and Goose are indicated as forwarder routes and have no live session yet. |

## D. Interception without changing the harness

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| D1 | For harnesses that cannot name their shell, command execution is forwarded by interception. | Preload a forwarder; a command prints the remote hostname. | yes | proven (evidence/interception/) |
| D2 | The forwarder never forwards itself, the transport, or the dynamic linker. | Process list shows no recursion. | yes | proven (evidence/interception/) |
| D3 | Signed, hardened or statically linked harness binaries are classified, with the supported route for each. | Table of binaries and results. | yes | proven (evidence/interception/provider-mac-d3.log) |
| D4 | If a virtual machine is required, its memory use is measured and bounded. | Resident memory under 1 GiB while idle and while running a task. | no | unproven (no guest was required, so memory was not measured; evidence/interception/provider-mac-d4.log) |
| D5 | The no-virtual-machine route is exercised for every harness where it is possible. | Same C-series tests with no guest running. | yes | proven (evidence/interception/provider-mac-d5.log). No guest was running. Claude, OpenCode, Codex, and Grok each ran a C session on that route. |

## E. Security and secrets

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| E1 | Harness credentials stay on the provider and are never copied to the remote. | Search the remote filesystem and process environment for the token after a session. | yes | proven (evidence/security/) |
| E2 | Provider secrets in shell startup files do not reach the remote unless allowed. | Canary secret in a startup file (see A4). | yes | proven (evidence/security/) |
| E3 | Transport is key-authenticated and limited to the private network. | Attempt a password login and a public-interface connection; both refused. | yes | proven (evidence/security/) |
| E4 | Logs never contain tokens or file contents. | Scan logs after a session. | yes | proven (evidence/security/) |
| E5 | A run can be fully revoked: keys, exports and mounts removed. | Teardown script followed by an access test. | yes | proven (evidence/security/linux-peer-e5.log, evidence/security/mac-peer-e5.log). Teardown removes the run key. On the peer whose operator ssh accepts a session with no key, the run listener is the revocation boundary and is gone after teardown. |

## F. Whole system

| ID | Assertion | Test | Req | Status |
| --- | --- | --- | --- | --- |
| F1 | One command starts a wrapped session for a chosen harness, remote and project; one command stops it and cleans up. | Run both on a clean machine. | yes | proven (evidence/whole/remote-linux-f1.log). One start left a wrapped session; one stop ended it and removed the project. |
| F2 | End to end: an unmodified harness fixes a failing test in a repository that exists only on the remote. The tests run on the remote, the commit lands on the remote, and nothing of the project is left on the provider. | The failing test passes on the remote; the provider has no copy. | yes | proven (evidence/whole/remote-linux-f2.log). An unmodified harness fixed the failing test on the remote, the commit landed there, and the provider copy was removed. |
| F3 | The harness was not modified, patched or re-signed. | Checksum of the harness binary before and after. | yes | proven (evidence/whole/remote-linux-f3.log). The harness checksum matched before and after the session. |
| F4 | A dropped connection mid-task recovers or fails clearly, with no corrupted files. | Kill the link during a write; verify the file is whole or absent. | yes | proven (evidence/whole/remote-linux-f4.log). Killing the transfer left the previous whole file, and a later push landed whole. |
| F5 | The setup reproduces from the repository's instructions on a second pair of machines. | A fresh operator follows the steps. | yes | proven (evidence/whole/f5-linux-f5.log, evidence/whole/f5-mac-f5.log, evidence/whole/f5-local-f5.log). The README file-plane command passed on a remote Linux peer and a remote Mac peer. The localhost exec suite passed 9 of 9. The provider mount command completed with the documented unsupported result. |
| F6 | Two sessions can use different remotes at once. | Two harnesses, two remotes, no cross-talk. | no | proven (evidence/whole/f6.log, evidence/whole/f6-claude.log). Two OpenCode sessions ran at the same time on a Linux and a Mac remote, and two Claude Code sessions ran at the same time on the same pair (`--harness claude`). Each saw its own host name and marker, each remote held only its own file, and neither output or local tree held anything from the other. The remote-file checks read stdout, not the ssh exit status, because the Mac remote's ssh always returns 0. |

## Order of proof

1. B1 and B2 first: without a readable remote file plane the file tools cannot go remote on that OS. This decides the design.
2. A1 to A9 in a real Claude session (C1) using the shell wrapper.
3. C2 and C3 once B passes.
4. D1 to D5 for harnesses the wrapper cannot reach.
5. E, then F1 to F5.

A required assertion that is shown impossible moves to `unsupported`, and the README states what that means for users.
