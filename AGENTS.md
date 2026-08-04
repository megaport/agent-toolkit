# Megaport Agent Toolkit — repository guide

This repo packages Megaport's skills, MCP connection and a self-installing CLI
into plugins for multiple AI coding assistants. It ships **one shared core** and
**thin per-host adapters**.

## Golden rule

`core/` is the only place you write anything. `dist/` is generated. If you find
yourself editing a file under `dist/`, stop — change `core/` or
`hosts/<host>/host.json` and re-run `./build.sh`.

CI runs `./build.sh` and then fails if `git status --porcelain -uall` reports
anything under `dist/` or the three marketplace dirs. Drift fails the build —
including *untracked* drift, which is what a new host or skill produces.

## Layout

```
core/
  toolkit.json          single source of truth: version, skills, MCP servers,
                        hooks, pinned versions, outbound-host allowlist
  skills/<name>/SKILL.md  host-neutral skills (see "Tokens" below)
  lib/*.sh              runtime shell the skills call
  hooks/*.sh            lifecycle hooks
hosts/<host>/host.json  adapter descriptor — the only thing a new host needs
build.sh                core x hosts -> dist/
dist/<host>/            generated, committed, consumed by marketplaces
tests/run.sh            lint + schema + hook-dialect + allowlist checks
```

## Tokens

Skills and hook configs are written host-neutrally and rendered at build time.
Never hardcode a host-specific path or variable in `core/`.

| Token | Rendered to |
|---|---|
| `{{PLUGIN_ROOT}}` | the host's plugin-root expression (`${CLAUDE_PLUGIN_ROOT}`, `${PLUGIN_ROOT}`, …) |
| `{{LIB}}` | `{{PLUGIN_ROOT}}/lib` |
| `{{VERSION}}` | `core/toolkit.json` → `.version` |
| `{{CLI_VERSION}}` | `core/toolkit.json` → `.pins.megaport_cli_version` |
| `{{DOCS_BASE}}` | `core/toolkit.json` → `.pins.docs_base_url` |

Plugin-root resolution is the single hardest portability problem here. Each host
exposes it differently and Cursor does not document one at all, so every script
in `core/lib/` is also **self-locating** (`$(cd "$(dirname "$0")" && pwd)`) and
works when invoked by absolute path. Token rendering is a convenience, not the
correctness mechanism. Do not remove the self-location preamble.

Self-location only starts helping once a script has been invoked, though — it
cannot rescue a path the model never resolved. Codex injects `PLUGIN_ROOT` into
hook subprocesses and nowhere else, so `hooks.json` renders fine but a skill body
telling the model to run `${PLUGIN_ROOT}/lib/mp-cli.sh` expands to
`/lib/mp-cli.sh`. The fix is the optional `skillPreamble` key in `host.json`: a
paragraph `build.sh` injects after the frontmatter of every generated
`SKILL.md`, rendered through the same token renderer. Hosts that omit the key get
byte-identical output to before. It is a host.json key precisely so `core/`
stays neutral — do not push a Codex workaround into a skill body.

## Adding a host

1. Create `hosts/<host>/host.json` (copy the closest existing one).
2. Add the host to the `HOSTS` list in `build.sh` — or nothing, if you let it
   glob; it globs.
3. `./build.sh && ./tests/run.sh`.
4. Add the new `dist/<host>` path to `.github/CODEOWNERS`.

No changes to `core/` should ever be required to add a host. If they are, the
abstraction is wrong — fix the abstraction.

## Host quirks worth knowing

- **Claude Code and Codex share a hook dialect.** Both use
  `hooks.json` with `{"hooks":{"PreToolUse":[{"matcher":…,"hooks":[…]}]}}`, both
  send `hook_event_name: "PreToolUse"` with `tool_name`/`tool_input`, and both
  read `hookSpecificOutput.permissionDecision` = `allow|deny|ask`. One script
  serves both.
- **Cursor is the odd one out.** Event is `beforeShellExecution`, stdin carries
  `command`/`cwd`, and denial is stdout `{"permission":"deny"}` with exit 2.
- **Codex's loader is lenient, its publication validator is not.** The runtime
  takes `skills` as a path or an array, `interface` optional, `hooks` as a path.
  `validate_plugin.py` (in the codex plugin-creator sample) takes `skills` as a
  string only, requires a full `interface`, and allows a fixed key set with no
  `hooks` in it. Build against the validator: a bundle that satisfies only the
  loader installs locally and fails publication. Hence
  `"manifest": {"flavour": "codex"}` in `hosts/codex/host.json` — manifest shape
  is a per-host concern, and the interface copy lives in `core/toolkit.json`
  because it is product metadata, not host configuration.
- **Omitting Codex's `hooks` manifest key is deliberate.** `hooks/hooks.json` is
  its default plugin hooks path, which is where `build.sh` writes it anyway.
  Naming it buys nothing and fails the validator.
- **A standalone `mcp.json` always carries the `{"mcpServers": …}` wrapper.**
  Codex's loader accepts a bare server map; its validator reads the same file as
  a pile of unknown top-level keys and rejects it. Claude Code is inline mode and
  embeds the bare map in `plugin.json` instead.
- **Cursor's marketplace is human-reviewed** and requires the repo to be open
  source. Its listing is not on our release cadence. Do not promise same-day
  parity across all three.
- **Codex marketplace** lives at `.agents/plugins/marketplace.json`; Claude Code
  at `.claude-plugin/marketplace.json`; Cursor at
  `.cursor-plugin/marketplace.json`. Three files, one generator.

## Runtime dependencies

User-facing scripts may rely on: `bash` (3.2+, macOS ships 3.2 — no associative
arrays, no `mapfile`), `curl`, `unzip`, and standard coreutils, plus **either**
`jq` **or** `python3` for JSON. `core/lib/common.sh` picks whichever is present
and fails with an actionable message if neither is. Build-time tooling
(`build.sh`, `tests/run.sh`) may require `jq` unconditionally.

## Network policy

Every host a script may contact is listed in `core/toolkit.json` →
`allowedHosts.hosts`. `tests/run.sh` greps `core/` for URLs and fails on any host
not on the list. This is the mechanism behind the "no telemetry" claim — keep it
working, use `mp_*` functions for network access and add hosts to the allowlist
deliberately, not reflexively.

## CI supply chain

GitHub Actions are the only third-party code this repo executes. Every `uses:`
in `.github/workflows/` is pinned to a **full 40-hex commit SHA** with a
trailing `# vX.Y.Z` comment; `tests/run.sh` → `workflows` fails the build on a
mutable tag or a missing version comment. Dependabot bumps the SHA and rewrites
the comment, so this costs nothing to maintain — do not "simplify" a pin back to
`@v7`.

Resolve a tag to its SHA with:

```
gh api repos/OWNER/REPO/commits/TAG --jq .sha
```

## Versioning

`core/toolkit.json` → `.version` drives every generated manifest. Bump it there
and nowhere else. Tag releases `v<version>`.
