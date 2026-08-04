---
name: megaport-terraform
description: Write and review Terraform for Megaport, grounded against the published provider schema from the Terraform Registry rather than recalled from memory. Covers megaport_port, megaport_vxc, megaport_mcr, megaport_mve, megaport_lag_port, megaport_ix and their data sources. Use whenever generating, editing or reviewing .tf files that provision Megaport infrastructure, or when the user asks about the Megaport Terraform provider.
---

> **Codex path note.** Toolkit commands are written against `${PLUGIN_ROOT}`, which Codex does not set in your shell — it injects that variable into hook subprocesses only. Derive it from this skill's own `<path>`: the plugin root is the directory two levels above this `SKILL.md`. Export it once per session, before the first toolkit command you run, e.g. `export PLUGIN_ROOT="$(cd "$(dirname <path to this SKILL.md>)/../.." && pwd)"`.

# Megaport Terraform provider

## Ground every attribute before you write it

Provider attributes change between minor versions and the model's recollection
of them is unreliable. Check the published schema first — it costs one command
and prevents an apply-time failure.

```bash
${PLUGIN_ROOT}/lib/mp-terraform.sh version              # which provider version is current
${PLUGIN_ROOT}/lib/mp-terraform.sh list resources       # every resource, current version
${PLUGIN_ROOT}/lib/mp-terraform.sh list data-sources
${PLUGIN_ROOT}/lib/mp-terraform.sh show megaport_vxc    # full docs for one resource
${PLUGIN_ROOT}/lib/mp-terraform.sh find bgp             # search slugs and titles
```

`show` prints the registry's own markdown: every argument, whether it is
required, whether it forces replacement, and the worked examples. Read it before
writing the resource block, not after the plan fails.

Docs are cached per provider version, so a provider release invalidates the
cache automatically.

## Workflow for generating configuration

1. **Read the existing repo first.** If there are `.tf` files, match their
   module layout, naming, variable style and provider version constraint. Do not
   introduce a second style.
2. **Resolve the schema** for every resource you are about to write.
3. **Pin the provider.** Always emit a `required_providers` block with a version
   constraint — an unpinned Megaport provider is how a working configuration
   silently breaks later.
4. **Write the HCL.**
5. **Describe the topology** before suggesting an apply. A short Mermaid diagram
   of what will be created and how it connects is worth more than a wall of HCL
   for review purposes:

   ```mermaid
   graph LR
     port[megaport_port: syd-primary] --> vxc[megaport_vxc: to-aws]
     vxc --> aws[AWS Direct Connect]
   ```

6. **`terraform plan`, then stop.** Show the plan. Do not run `apply`.

## Applies

`terraform apply`, `destroy`, `import` and `state` mutations are intercepted by
the `PreToolUse` hook and escalated to the user. This is the normal Terraform
review step, enforced rather than assumed.

Read the plan output before presenting it. If it shows a **replace** on a
provisioned service, say so explicitly and in plain language — a replace on a
`megaport_port` or `megaport_vxc` is a real service interruption and a billing
event, and it is easy to miss inside a long plan diff.

## Terraform MCP server (optional)

HashiCorp's Terraform MCP server adds registry-wide search and module lookup
across *all* providers, which is useful in a repo that connects Megaport to AWS,
Azure or Google.

It is **not enabled by default** because it requires Docker. The plugin ships it
as `mcp.optional.json` at the plugin root; merge that file's `mcpServers` entry
into your host's MCP configuration:

```json
{
  "mcpServers": {
    "terraform": {
      "type": "stdio",
      "command": "docker",
      "args": ["run", "-i", "--rm", "hashicorp/terraform-mcp-server"]
    }
  }
}
```

When it is available, use it for cross-provider questions. For Megaport's own
schema, `mp-terraform.sh` is faster and needs no daemon.

## Credentials

The provider takes its own credentials, separate from both the MCP OAuth session
and the CLI's configuration. Never write access keys into a `.tf` file — use
environment variables or a `terraform.tfvars` that is gitignored, and say so when
you generate the configuration.