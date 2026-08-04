#!/usr/bin/env bash
# Query the Megaport Terraform provider's published documentation.
#
# Reads the Terraform Registry API directly, so the schema an agent generates HCL
# against is the schema that is actually published — not whatever the model
# remembers. Resolves the provider version once and caches per version, so a
# provider release invalidates the cache automatically.
#
# Usage:
#   mp-terraform.sh version                     resolve + print the latest provider version
#   mp-terraform.sh categories                  list available doc categories
#   mp-terraform.sh list [CATEGORY]             list docs (default: resources)
#   mp-terraform.sh show SLUG [CATEGORY]        print a doc in full (markdown)
#   mp-terraform.sh find QUERY                  search doc slugs/titles across categories
#   mp-terraform.sh refresh                     drop the cache
#
# CATEGORY is one of: resources, data-sources, guides, overview
#
# Example:
#   mp-terraform.sh list resources
#   mp-terraform.sh show megaport_vxc resources

set -euo pipefail
# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

REGISTRY="https://registry.terraform.io"
TTL="${MP_TF_TTL:-86400}"

provider() { printf '%s' "$(mp_pin terraform_provider)"; }   # e.g. megaport/megaport

# jq when available, python3 otherwise. These projections pair fields on one
# line, which the generic mp_json dotted-path subset deliberately cannot do.
tf_pick_version() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '[.included[] | select(.type=="provider-versions")]
           | sort_by(.attributes["published-at"]) | last
           | "\(.id)\t\(.attributes.version)"'
  else
    python3 -c '
import sys, json
d = json.load(sys.stdin)
vs = [x for x in d.get("included", []) if x.get("type") == "provider-versions"]
if not vs:
    sys.exit("no provider-versions in registry response")
vs.sort(key=lambda x: x["attributes"]["published-at"])
print("%s\t%s" % (vs[-1]["id"], vs[-1]["attributes"]["version"]))'
  fi
}

tf_pick_docs() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data[] | "\(.id)\t\(.attributes.slug)\t\(.attributes.title)"'
  else
    python3 -c '
import sys, json
for x in json.load(sys.stdin).get("data", []):
    a = x["attributes"]
    print("%s\t%s\t%s" % (x["id"], a.get("slug", ""), a.get("title", "")))'
  fi
}

tf_pick_content() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.data.attributes.content'
  else
    python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["attributes"]["content"])'
  fi
}

# Resolve the provider version id, caching for TTL. Prints "<version-id>\t<version>".
tf_version_pair() {
  local f; f="$(mp_cache_dir terraform)/version"
  if ! mp_cache_fresh "$f" "$TTL"; then
    mp_log "resolving latest $(provider) provider version"
    mp_curl "$REGISTRY/v2/providers/$(provider)?include=provider-versions" \
      | tf_pick_version > "$f.partial"
    mv "$f.partial" "$f"
  fi
  cat "$f"
}

tf_version_id() { tf_version_pair | cut -f1; }
tf_version()    { tf_version_pair | cut -f2; }

# List docs for a category, cached per (version, category) so a provider bump
# invalidates it for free.
tf_docs() {
  local cat="${1:-resources}" vid f
  vid="$(tf_version_id)"
  f="$(mp_cache_dir "terraform/$vid")/$cat.tsv"
  if ! mp_cache_fresh "$f" "$TTL"; then
    mp_curl "$REGISTRY/v2/provider-docs?filter%5Bprovider-version%5D=$vid&filter%5Bcategory%5D=$cat&page%5Bsize%5D=100" \
      | tf_pick_docs > "$f.partial"
    mv "$f.partial" "$f"
  fi
  cat "$f"
}

cmd_categories() { printf '%s\n' resources data-sources guides overview; }

cmd_list() {
  local cat="${1:-resources}" prefix=""
  # Registry slugs drop the provider prefix; print the name as it appears in HCL.
  case "$cat" in resources|data-sources) prefix="megaport_" ;; esac
  mp_log "$(provider) v$(tf_version) — $cat"
  tf_docs "$cat" | awk -F'\t' -v p="$prefix" '
    { name = p $2; printf "%s%s\n", name, ($3 != "" && $3 != $2 ? "  — " $3 : "") }'
}

cmd_show() {
  local slug="${1:?usage: mp-terraform.sh show SLUG [CATEGORY]}" cat="${2:-}" id=""

  # Registry slugs omit the provider prefix: megaport_vxc -> vxc
  local bare="${slug#megaport_}"

  local cats="$cat"
  [ -n "$cats" ] || cats="resources data-sources guides overview"

  local c
  for c in $cats; do
    id="$(tf_docs "$c" | awk -F'\t' -v s="$bare" '$2 == s {print $1; exit}')"
    [ -n "$id" ] && { cat="$c"; break; }
  done

  if [ -z "$id" ]; then
    mp_warn "no doc named '$bare' in ${cat:-any category} for $(provider) v$(tf_version)"
    mp_warn "available in resources:"
    tf_docs resources | awk -F'\t' '{print "  megaport_" $2}' >&2
    return 1
  fi

  mp_log "$(provider) v$(tf_version) — $cat/$bare"
  mp_curl "$REGISTRY/v2/provider-docs/$id" | tf_pick_content
}

cmd_find() {
  local q="${1:?usage: mp-terraform.sh find QUERY}" c found=0
  for c in resources data-sources guides overview; do
    local hits
    hits="$(tf_docs "$c" | grep -i -- "$q" || true)"
    if [ -n "$hits" ]; then
      found=1
      printf '%s:\n' "$c"
      printf '%s\n' "$hits" | awk -F'\t' '{printf "  %-38s %s\n", $2, $3}'
    fi
  done
  [ "$found" -eq 1 ] || mp_log "nothing matched '$q' in $(provider) v$(tf_version)"
}

cmd_refresh() { rm -rf "$(mp_cache_dir terraform)"; mp_log "terraform doc cache cleared"; }

case "${1:-}" in
  version)    tf_version; printf '\n' ;;
  categories) shift; cmd_categories "$@" ;;
  list)       shift; cmd_list "$@" ;;
  show)       shift; cmd_show "$@" ;;
  find)       shift; cmd_find "$@" ;;
  refresh)    shift; cmd_refresh "$@" ;;
  ""|-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) mp_die "unknown command: $1 (try --help)" ;;
esac