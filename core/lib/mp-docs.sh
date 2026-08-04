#!/usr/bin/env bash
# Query the public Megaport documentation at docs.megaport.com.
#
# Retrieval strategy, cheapest first:
#   1. llms.txt      — a ~43KB curated index of every page (title + URL, grouped
#                      into sections). Walk this to find the right page.
#   2. <page>.md     — Mintlify serves a clean markdown rendering of each page at
#                      the page URL with a .md suffix. Fetch only what you need.
#   3. llms-full.txt — a ~3.5MB concatenation of the entire corpus. Full-text
#                      grep, used only when the index doesn't surface the answer.
#
# Step 2 is content-sniffed, not assumed: the site is mid-migration to Mintlify
# and today still answers `<page>.md` with the HTML shell. When that happens this
# script says so and routes you to step 3, so it works before and after cutover.
#
# Usage:
#   mp-docs.sh sections                 list top-level documentation sections
#   mp-docs.sh list [SECTION]           list pages (optionally within a section)
#   mp-docs.sh find QUERY               search page titles and URLs in the index
#   mp-docs.sh page URL|PATH            fetch one page as markdown
#   mp-docs.sh grep QUERY [-C N]        full-text search across the whole corpus
#   mp-docs.sh refresh                  force re-download of both caches
#
# Caches live under $MEGAPORT_TOOLKIT_CACHE/docs with a 24h TTL.

set -euo pipefail
# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

TTL="${MP_DOCS_TTL:-86400}"

docs_base()  { printf '%s' "$(mp_pin docs_base_url)"; }
index_file() { printf '%s/llms.txt' "$(mp_cache_dir docs)"; }
full_file()  { printf '%s/llms-full.txt' "$(mp_cache_dir docs)"; }

fetch_index() {
  local f; f="$(index_file)"
  if [ "${1:-}" = "--force" ] || ! mp_cache_fresh "$f" "$TTL"; then
    mp_log "fetching docs index ($(docs_base)/llms.txt)"
    mp_curl "$(docs_base)/llms.txt" --output "$f.partial"
    mv "$f.partial" "$f"
  fi
  printf '%s' "$f"
}

fetch_full() {
  local f; f="$(full_file)"
  if [ "${1:-}" = "--force" ] || ! mp_cache_fresh "$f" "$TTL"; then
    mp_log "fetching full docs corpus (~3.5MB, cached for 24h)"
    mp_curl "$(docs_base)/llms-full.txt" --output "$f.partial"
    mv "$f.partial" "$f"
  fi
  printf '%s' "$f"
}

cmd_sections() {
  grep -E '^##[[:space:]]' "$(fetch_index)" | sed -E 's/^##[[:space:]]*//'
}

cmd_list() {
  local section="${1:-}" idx
  idx="$(fetch_index)"
  if [ -z "$section" ]; then
    grep -oE '\[[^]]+\]\(https?://[^)]+\)' "$idx" | sed -E 's/^\[(.*)\]\((.*)\)$/\1\t\2/'
    return
  fi
  # Print entries between the matching `## Section` and the next `## `.
  awk -v want="$section" '
    /^##[[:space:]]/ {
      hdr = $0; sub(/^##[[:space:]]*/, "", hdr)
      inside = (tolower(hdr) == tolower(want))
      next
    }
    inside
  ' "$idx" | grep -oE '\[[^]]+\]\(https?://[^)]+\)' | sed -E 's/^\[(.*)\]\((.*)\)$/\1\t\2/'
}

cmd_find() {
  local q="${1:?usage: mp-docs.sh find QUERY}" idx hits
  idx="$(fetch_index)"
  hits="$(grep -oE '\[[^]]+\]\(https?://[^)]+\)' "$idx" \
          | grep -i -- "$q" \
          | sed -E 's/^\[(.*)\]\((.*)\)$/\1\t\2/' || true)"
  if [ -z "$hits" ]; then
    mp_log "no page titles matched '$q'. Try: mp-docs.sh grep '$q'"
    return 0
  fi
  printf '%s\n' "$hits"
}

# Extract one page from the cached corpus. llms-full.txt delimits pages with a
# `**Source:** <url>` marker and a rule of dashes, so this yields the exact page
# rather than a keyword-matched fragment.
page_from_corpus() {
  local url="$1" bare="${1%/}"
  awk -v a="**Source:** $bare" -v b="**Source:** $bare/" '
    !inpage && ($0 == a || $0 == b) { inpage = 1; next }
    inpage && /^-{20,}[[:space:]]*$/ { exit }
    inpage { print }
  ' "$(fetch_full)"
}

# Fetch a single page as markdown. Accepts a full URL or a site-relative path.
cmd_page() {
  local ref="${1:?usage: mp-docs.sh page URL|PATH}" url md body

  case "$ref" in
    https://*) url="$ref" ;;
    /*)        url="$(docs_base)$ref" ;;
    *)         url="$(docs_base)/$ref" ;;
  esac

  # Mintlify convention: strip any trailing slash, append .md
  md="$(printf '%s' "$url" | sed -E 's#/+$##').md"
  body="$(mp_curl "$md" 2>/dev/null || true)"

  # Sniff rather than assume: an un-migrated site answers .md with the HTML app
  # shell, and a soft-404 returns 200 with the same shell.
  case "$(printf '%s' "$body" | head -c 400 | tr '[:upper:]' '[:lower:]')" in
    ""|*"<!doctype html"*|*"<html"*) ;;
    *) printf '%s\n' "$body"; return ;;
  esac

  mp_log "$md is not serving markdown yet — extracting the page from the cached corpus instead."
  body="$(page_from_corpus "$url")"

  if [ -n "$body" ]; then
    printf '%s\n' "$body"
    return
  fi

  mp_warn "no page found at $url."
  mp_warn "Check the URL with: mp-docs.sh find <keyword>"
  return 1
}

cmd_grep() {
  local q="${1:?usage: mp-docs.sh grep QUERY [-C N]}"; shift || true
  local ctx=8
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|--context) ctx="${2:?-C requires a number}"; shift 2 ;;
      *) mp_die "unknown option: $1" ;;
    esac
  done

  grep -i -n -C "$ctx" -- "$q" "$(fetch_full)" || {
    mp_log "no matches for '$q' in the full corpus."
    mp_log "Try a broader term, or the product's formal name (e.g. 'virtual cross connect' as well as 'VXC')."
    return 0
  }
}

cmd_refresh() { fetch_index --force >/dev/null; fetch_full --force >/dev/null; mp_log "docs cache refreshed"; }

case "${1:-}" in
  sections) shift; cmd_sections "$@" ;;
  list)     shift; cmd_list "$@" ;;
  find)     shift; cmd_find "$@" ;;
  page)     shift; cmd_page "$@" ;;
  grep)     shift; cmd_grep "$@" ;;
  refresh)  shift; cmd_refresh "$@" ;;
  ""|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) mp_die "unknown command: $1 (try --help)" ;;
esac
