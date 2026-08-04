---
name: megaport-docs
description: Search and read the public Megaport documentation at docs.megaport.com — product guides, configuration steps, troubleshooting, limits and quotas, and reference material for Ports, VXCs, MCR, MVE, Internet Exchange, cloud onramps (AWS, Azure, Google, Oracle, IBM), billing and Terraform. Use for any "how do I", "what is", "is it possible to", "what are the limits" question about how Megaport works or how customers configure it. Do not answer Megaport product questions from memory — search here.
allowed-tools: Bash({{LIB}}/mp-docs.sh:*)
---

# Megaport documentation

## Why not answer from memory

Megaport ships continuously and the model's training data lags. Location IDs,
supported bandwidths, cloud onramp procedures and quota limits all change. Search
before answering.

## Retrieval order — cheapest first

Work down this list. Stop as soon as you have the answer.

**1. Walk the index.** A curated list of every page, ~43KB, grouped by section.

```bash
{{LIB}}/mp-docs.sh sections                 # top-level sections
{{LIB}}/mp-docs.sh list "Cloud Connectivity"  # pages within one section
{{LIB}}/mp-docs.sh find "MCR"               # match page titles and URLs
```

**2. Read the specific page.** Once `find` gives you a URL, fetch just that page
as markdown rather than searching the whole corpus.

```bash
{{LIB}}/mp-docs.sh page https://docs.megaport.com/mcr/
{{LIB}}/mp-docs.sh page /connections/aws/    # site-relative also works
```

**3. Full-text search, only if the index failed you.** The whole corpus is ~3.5MB.
Grepping it is the fallback, not the default — it returns fragments without their
surrounding page context, which is how confident-but-wrong answers happen.

```bash
{{LIB}}/mp-docs.sh grep "BGP prefix limit" -C 15
```

## Getting good results

- **Search both the acronym and the expansion.** "VXC" and "virtual cross
  connect" hit different prose. Same for MCR/Megaport Cloud Router,
  MVE/Megaport Virtual Edge, IX/Internet Exchange.
- **Two or three narrow searches beat one broad one.** `find` on a broad term
  returns a page list — that list is itself useful for orienting.
- **Cite the page URL** when you answer. The user will want to read it.
- **Summarise, don't paste.** Raw `grep -C` output is noisy.
- `{{LIB}}/mp-docs.sh refresh` forces a re-download when the user asks about
  something just released.

## Scope

This is the **public customer documentation** only. It does not cover internal
runbooks, the private API surface, or unreleased features. If the answer isn't
there, say it isn't there rather than reconstructing something plausible.

For live account state (what services exist, their status, diagnostics) use the
Megaport MCP tools instead — documentation cannot answer those.

## A note on the site migration

docs.megaport.com is moving to Mintlify. `page` requests the Mintlify-style
`<url>.md` endpoint and **sniffs the response** rather than assuming — a site
that hasn't cut over answers `.md` with its HTML shell, and returns HTTP 200
while doing it.

If markdown doesn't come back, `page` extracts the same page out of the cached
corpus instead: `llms-full.txt` delimits every page with a `**Source:** <url>`
marker, so you still get the exact page, not a keyword-matched fragment. You get
clean per-page markdown either way, and nothing changes for you at cutover.
