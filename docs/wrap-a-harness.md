# Can this harness be wrapped?

Run these steps in order for any harness. Each step has a command and a result you can read. Stop at the first route that works.

The automatic steps (1 to 4) are `tests/coverage/c9.sh`:

```
tests/coverage/c9.sh <command-name> [<command-name> ...]
```

It prints one line per harness and writes `evidence/coverage/provider-mac-c9.log`.

## Steps

1. **What runs?** `file $(command -v <harness>)`.
   A Mach-O binary is the harness. A script is a launcher: follow its `exec` line, or its `#!` interpreter, to the real binary and use that file from here on.
2. **Dynamic or static, signed or not?**
   `otool -L <binary>` lists libraries. No list means static.
   `codesign -d --verbose=2 <binary>` shows `flags=`. `runtime` means hardened. `adhoc` or `linker-signed` means the loader still honors `DYLD_INSERT_LIBRARIES`.
3. **Does it name a shell setting?**
   `strings -a <binary> | grep -o -E '\b[A-Z][A-Z0-9_]*_SHELL\b' | sort -u`.
   A name that the harness documents (for example `CLAUDE_CODE_SHELL`) is the first route to try: point it at `src/rw-bash`. A name in the list is only a hint. `GROK_SHELL` appears in Grok and Grok did not run it (C8).
   Also try the plain `SHELL` variable.
4. **Does the forwarder load?**
   Build `src/forwarder-mac.c`, then run the binary with `DYLD_INSERT_LIBRARIES=<dylib> RW_LOG=<file> <binary> --version`.
   `decision=loaded` in the log means the loader accepted it. No line means a hardened or static binary refused it.
5. **Prove it in a live session.** This step needs a model account.
   Set the route from step 3 or 4, run one real turn that asks the harness for one shell command, and check two things: the command printed the remote host name, and a file only the remote has was read. The logs for C1 to C8 are examples.

## Reading the result

| Step 3 | Step 4 | Route |
| --- | --- | --- |
| documented shell setting | any | set it to `src/rw-bash`, then step 5 |
| none | loaded | DYLD forwarder, then step 5 |
| none | not loaded, hardened or static | no interception; list the harness as unsupported with this reason |
| none | not loaded, not hardened | not observed; retry step 4 on the real binary, not the launcher |

The harness binary is never edited or re-signed (F3). A route that needs either is unsupported.

## What was run

`evidence/coverage/provider-mac-c9.log` holds the output for six harnesses on one Mac.
The procedure reproduced the routes already measured in D3 and C8: Claude Code uses its shell setting, OpenCode and Codex use the forwarder, Grok has no route.
Pi and Goose are indicated as forwarder routes by steps 1 to 4. Step 5 has not been run for them, so they are not listed as wrapped.
