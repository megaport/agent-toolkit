---
name: megaport-cli
description: Run the Megaport CLI. Downloads, checksum-verifies and version-pins the correct binary for this machine on first use, then executes it. Use when the user wants a reproducible command they can commit, put in a runbook or run in CI, when they explicitly ask for the CLI, or when a Megaport operation needs a surface the MCP tools do not expose. Triggers include "megaport-cli", "CLI", "command line", "script this", "runbook", "in CI".
---

# Megaport CLI

## Running it

Always go through the wrapper. It resolves the OS/arch, verifies the download
against the published `SHA256SUMS`, caches it under a version-pinned path and
execs it. Arguments pass straight through.

```bash
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --help
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh locations list
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh ports list --output json
```

Housekeeping:

```bash
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --install    # download + verify, don't run
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --path       # where the pinned binary lives
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --version    # which version is pinned
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --system …   # use megaport-cli from PATH instead of the pin
```

First run downloads ~7MB. Later runs are local.

## Discover before you guess

The CLI's command tree is not something to reconstruct from memory. Ask it:

```bash
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh --help
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh <group> --help
```

If a command you expected doesn't exist, check `--help` output rather than
trying variations — the pinned version is **1.0.0-beta.2**, and the CLI is
pre-1.0, so its surface moves between releases.

## When to reach for the CLI instead of MCP

The MCP tools are better for reading — no install, structured results, already
authenticated. Prefer the CLI when:

- the user wants an artefact: something to commit, paste into a runbook, or
  schedule in CI;
- the operation isn't exposed as an MCP tool;
- the environment is headless or SSO-restricted and the OAuth browser flow is
  unavailable.

Reading the same data twice through both surfaces is wasted work. Pick one.

## Authentication

The CLI has its own credentials, separate from the MCP server's OAuth session.
Being authenticated in one does not authenticate the other.

```bash
${CURSOR_PLUGIN_ROOT:-$HOME/.cursor/plugins/local/megaport-agent-toolkit}/lib/mp-cli.sh configure          # interactive
```

or export `MEGAPORT_ACCESS_KEY` / `MEGAPORT_SECRET_KEY`.

**Never** echo, log, or write credentials into a file in the workspace. If the
user pastes a key into the conversation, use it for the call and do not repeat
it back.

## Mutating commands

Anything that is not a recognised read-only verb is intercepted by the
`PreToolUse` hook and escalated to the user for approval before it runs. That is
deliberate — do not attempt to route around it by invoking the binary directly,
constructing the command in a subshell, or using `curl` against the API.

Before a mutating command, tell the user in plain language what it will do:
which service, which account, and whether it is billable or reversible. The
approval prompt shows a command line, which is not the same as informed consent.

## Version pinning

The pinned version lives in `toolkit.json` and is bumped deliberately by a
maintainer. It is not resolved at runtime, because `megaport-cli` publishes every
release as a GitHub pre-release — `/releases/latest` returns 404, so "just use
latest" does not work. Override with `MEGAPORT_CLI_VERSION` if you need a
specific build.