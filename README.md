# remote-harness-wrap

Run an unmodified AI coding harness (Claude Code, OpenCode, Codex, others) on one machine while every command it runs and every file it touches lands on another machine. The harness is not patched and does not know.

This repository starts with `ASSERTIONS.md`: the list of claims that must each be proven, with evidence, before the whole system counts as working. Nothing is built until its assertion is written down here.

Rules for this repository:

- An assertion is proven only by an observable result recorded under `evidence/`, never by reading code.
- A harness that cannot be proven is listed as unsupported, not omitted.
- No credentials, hostnames or account names are committed.
