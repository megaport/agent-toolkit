---
name: megaport
description: Orientation for working with Megaport — what the account has connected, and which surface (MCP, CLI, Terraform, docs) answers which kind of question. Use when a Megaport request is ambiguous about surface, when the user asks what the Megaport toolkit can do, or when a Megaport operation has failed and you need to pick a different route. Triggers include "Megaport", "what can you do with Megaport", "how do I connect to Megaport", "Megaport setup".
---

> **Codex path note.** Toolkit commands are written against `${PLUGIN_ROOT}`, which Codex does not set in your shell — it injects that variable into hook subprocesses only. Derive it from this skill's own `<path>`: the plugin root is the directory two levels above this `SKILL.md`. Export it once per session, before the first toolkit command you run, e.g. `export PLUGIN_ROOT="$(cd "$(dirname <path to this SKILL.md>)/../.." && pwd)"`.

# Megaport Agent Toolkit

Four surfaces are available. They are not interchangeable — picking the wrong
one is the most common cause of a wrong answer.

| Question | Surface | Skill |
|---|---|---|
| "What's on my account right now?" | **MCP** (`mcp.megaport.com`) | tools are already connected — call them directly |
| "How does X work / how do I configure Y?" | **Docs** | `megaport-docs` |
| "Write me Terraform for Z" | **Provider docs** | `megaport-terraform` |
| "Give me a command I can commit / run in CI" | **CLI** | `megaport-cli` |

## Choosing a surface

**Live account state → MCP, always.** The MCP tools (`list_services`,
`get_service_details`, `get_vxc_diagnostics`, `get_mcr_diagnostics`,
`get_network_status`, `list_locations`, `get_pricing`, …) read the account
directly. Never answer a "what do I have" question from documentation or from
memory — read it.

**Conceptual or procedural → docs.** Anything phrased as "how does", "what is",
"can I", "what are the limits". The docs skill searches the published corpus
rather than relying on what the model recalls, which for a product with
Megaport's release cadence is frequently stale.

**Infrastructure as code → Terraform.** If the user has `.tf` files in the
workspace, or asks for something repeatable, generate HCL grounded against the
published provider schema. Do not write HCL from memory — provider attributes
change between minor versions.

**Reproducible one-off → CLI.** When the user wants something they can paste
into a runbook, commit, or hand to on-call.

## Overlaps worth knowing

- MCP and the CLI both read live state. Prefer **MCP for reading** (no install,
  structured results) and the **CLI for anything the user wants to keep**.
- Docs and provider docs overlap on Terraform topics. The provider registry is
  authoritative for *schema*; docs.megaport.com is better for *why* and for
  worked examples.

## Safety

Commands that can change live infrastructure are intercepted by a `PreToolUse`
hook and escalated to the user before they run. This covers the shell path —
`megaport-cli`, `terraform apply`, `terraform destroy` and friends.

It does **not** cover every route to the API. Do not tell the user that nothing
can change without their approval. What is true: shell commands that mutate get
a prompt, and Terraform keeps its normal plan/apply review.

When you are about to do something destructive, say what it will affect in plain
terms before the prompt appears — a bare approval dialog with a long command in
it is not informed consent.

## Authentication

The MCP server authenticates over OAuth on first tool call. The CLI uses its own
credentials (`megaport-cli configure`, or `MEGAPORT_ACCESS_KEY` /
`MEGAPORT_SECRET_KEY`). Terraform uses the provider's own credential block. These
are three separate credential paths — an authenticated MCP session does not
authenticate the CLI, and vice versa. If one surface 401s, the others may still
be fine.