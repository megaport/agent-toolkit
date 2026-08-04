# Megaport Agent Toolkit

Megaport skills, hosted MCP connection and CLI tool — packaged for AI coding assistants.

Everything here already exists on its own: the [MCP server](https://mcp.megaport.com), the [CLI](https://github.com/megaport/cli), the [Terraform provider](https://registry.terraform.io/providers/megaport/megaport), and [the docs](https://docs.megaport.com). This packages it up into harness-specific plugins to make installation and configuration simpler.

## Install

**Claude Code**

```
/plugin marketplace add megaport/agent-toolkit
/plugin install megaport-agent-toolkit@megaport
```

**Codex CLI**

```
codex plugin marketplace add megaport/agent-toolkit
codex plugin add megaport-agent-toolkit
```

**Cursor**

Install from the Cursor marketplace, or for local testing:

> [!WARNING]
> Cursor marketplace listing is a work in progress. Manual install steps listed for now.

```
git clone https://github.com/megaport/agent-toolkit
ln -s "$PWD/agent-toolkit/dist/cursor" ~/.cursor/plugins/local/megaport-agent-toolkit
```

Restart your assistant afterwards so it picks up the new skills.

## What you get

| Component | What it does |
|---|---|
| **MCP connection** | Authenticated connection to `mcp.megaport.com` — live account state, service diagnostics, locations, pricing. OAuth on first tool call, you choose access level. |
| `megaport-docs` | Walks the published documentation index, fetches individual pages as markdown, full-text search as a fallback. |
| `megaport-terraform` | Resolves the provider schema from the Terraform Registry so generated HCL matches the version you're actually using. |
| `megaport-cli` | Downloads, checksum-verifies and version-pins the right CLI binary for your machine, then runs it. |
| `megaport` | Orientation: which surface answers which kind of question. |

## Requirements

`bash`, `curl`, `unzip`, and either `jq` or `python3`. On macOS and most Linux
distributions that's everything already installed except possibly `jq`.

## Safety

A `PreToolUse` hook intercepts shell commands that can change live
infrastructure — `megaport-cli` verbs outside the read-only set, and
`terraform apply` / `destroy` / `import` / `state` mutations — and escalates them
to you for approval before they run. (Cursor's hook API has no ask action, so
there the command is blocked with an explanation instead of prompting.)

The classifier is **fail-closed**: read verbs are allowlisted and anything
unrecognised prompts. A verb added by a future CLI release prompts by default
rather than slipping through.

**What this does not do.** It classifies shell commands as text. A command
obfuscated so the guarded name never appears in that text — `eval`, strings
built from variables — can evade it, and it does not prevent an assistant
reaching the API another way: a raw `curl`, a script, or an MCP tool call.
Terraform applies still run under your own credentials with the normal plan
and apply review. This is a strong control on the ordinary shell path, not a
guarantee that nothing changes without your approval, and we would rather say
so than have you find out during a security review.

## Auditability

- MIT licensed, source public.
- Every host the toolkit may contact is declared in
  [`core/toolkit.json`](core/toolkit.json) under `allowedHosts`. CI fails if any
  script references a host that isn't on the list, and `mp_curl` re-checks at
  runtime — every hop of a redirect, not just the URL it was handed. That makes
  "no telemetry" a testable claim rather than an assertion.
- The toolkit writes no log files of its own; its diagnostics land in your
  terminal and the agent's session transcript. A best-effort filter redacts
  known credential shapes (auth headers, token/key pairs, `MEGAPORT_*` values,
  JWTs) at write time before they get there. It is pattern-based — a shape it
  has never seen gets through — and it cannot reach output the CLI writes on
  its own, so the flags that produce that — `--log-http`, `--base-url`,
  `--token-url` — are refused by the wrapper and escalated by the hook. The
  stronger property is that the toolkit's own scripts never read or handle
  your credentials at all; only the CLI does.
- CLI downloads are verified against the published `SHA256SUMS` and refuse to
  install on a mismatch, a missing entry, or a missing checksum tool.

## Development

`core/` is the single source of truth. `dist/` is generated and committed.

```
./build.sh                # core/ x hosts/ -> dist/
./build.sh claude-code    # one target
./build.sh --check        # fail if dist/ is stale
./tests/run.sh            # lint, schema, allowlist, hook dialects, dist drift
./tests/run.sh --network  # plus live retrieval
```

Adding a target means writing one `hosts/<host>/host.json` — no changes to
`core/`. See [AGENTS.md](AGENTS.md) for the full contributor guide, including
the per-target quirks (Claude Code and Codex share a hook dialect; Cursor doesn't).

## Host support

| Host | Status | Notes |
|---|---|---|
| Claude Code | GA | |
| Codex CLI | GA | |
| Cursor | Coming Soon | Pending marketplace listing |
| Windsurf, Gemini CLI, JetBrains Junie, Continue.dev | planned | |
