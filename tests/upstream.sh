#!/usr/bin/env bash
# Validate the generated manifests against each host's UPSTREAM publication
# schema, pinned by commit SHA and verified by SHA256 before it runs.
#
#   ./tests/upstream.sh           fetch the pinned validators and run them
#   ./tests/upstream.sh --latest  resolve the current upstream pins and print an
#                                 updated tests/upstream.pins.json to stdout
#
# Why this is not a group inside tests/run.sh:
#   run.sh is offline bash+jq, and its --network group is `continue-on-error` in
#   CI because an upstream outage must not block a pull request. A manifest that
#   violates a host's publication schema is not an outage — it is a defect that
#   would ship — so it gets a job of its own that is allowed to fail nothing.
#
# What passing does and does not prove:
#   A host's runtime loader and its publication validator are different programs
#   with different strictness. Every host checked here will happily LOAD a
#   manifest this script rejects — that asymmetry is the whole reason it exists.
#   Green means the bundle can be published, not that it loads.
#
# Dependencies: curl, jq, python3 with `jsonschema` and `pyyaml`.
#   pip install jsonschema pyyaml
# A missing dependency is a failure, not a skip. This script is a gate, and a
# gate that waves things through when it cannot run is not one.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/tests/upstream.pins.json"
RAW="https://raw.githubusercontent.com"
API="https://api.github.com"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v jq   >/dev/null 2>&1 || { echo "tests/upstream.sh needs jq on PATH" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "tests/upstream.sh needs curl on PATH" >&2; exit 1; }

# Same two-implementation dance as core/lib/mp-cli.sh: macOS ships shasum, most
# Linux images ship sha256sum, and neither ships both.
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else echo "neither 'shasum' nor 'sha256sum' available — cannot verify downloads" >&2; exit 1
  fi
}

p() { jq -r "$1" "$PINS"; }

# ---------------------------------------------------------------- --latest

# Resolve each pin to what upstream currently publishes and emit an updated pins
# file on stdout; everything else goes to stderr so the output is pasteable:
#
#   ./tests/upstream.sh --latest > /tmp/pins && mv /tmp/pins tests/upstream.pins.json
#
# Deliberately a separate, human-run step. Auto-bumping a pin in CI would defeat
# it: the point of the pin is that a maintainer sees the diff.
if [ "${1:-}" = "--latest" ]; then
  updated="$(cat "$PINS")"

  for key in $(p '.files | keys[]'); do
    repo="$(p ".files[\"$key\"].repo")"
    track="$(p ".files[\"$key\"].track")"
    path="$(p ".files[\"$key\"].path")"

    case "$track" in
      main)
        meta="$(curl -fsSL "$API/repos/$repo/commits/main")" || { echo "cannot reach $repo" >&2; exit 1; }
        ref="$(printf '%s' "$meta" | jq -r .sha)"
        name="main @ $(printf '%s' "$meta" | jq -r '.commit.committer.date' | cut -dT -f1)"
        ;;
      release)
        tag="$(curl -fsSL "$API/repos/$repo/releases/latest" | jq -r .tag_name)"
        ref="$(curl -fsSL "$API/repos/$repo/commits/$tag" | jq -r .sha)"
        name="$tag"
        ;;
      *) echo "unknown track '$track' for $key" >&2; exit 1 ;;
    esac

    tmp="$(mktemp)"
    curl -fsSL -o "$tmp" "$RAW/$repo/$ref/$path" || { echo "cannot fetch $repo@$ref/$path" >&2; exit 1; }
    hash="$(sha256_of "$tmp")"; rm -f "$tmp"

    printf '%-26s %s  %s\n' "$key" "$name" "$ref" >&2
    updated="$(printf '%s' "$updated" | jq --arg k "$key" --arg r "$ref" --arg n "$name" --arg h "$hash" \
      '.files[$k].ref = $r | .files[$k].refName = $n | .files[$k].sha256 = $h')"
  done

  for key in $(p '.clis | keys[]'); do
    pkg="$(p ".clis[\"$key\"].package")"
    ver="$(npm view "$pkg" version 2>/dev/null)" || { echo "cannot resolve $pkg from npm" >&2; exit 1; }
    printf '%-26s %s\n' "$key" "$ver" >&2
    updated="$(printf '%s' "$updated" | jq --arg k "$key" --arg v "$ver" '.clis[$k].version = $v')"
  done

  printf '%s\n' "$updated"
  exit 0
fi

# ---------------------------------------------------------------- deps

group "dependencies"

for dep in jsonschema yaml; do
  if python3 -c "import $dep" 2>/dev/null; then
    ok "python3 module: $dep"
  else
    bad "python3 module: $dep" "pip install jsonschema pyyaml"
  fi
done

[ "$FAIL" -eq 0 ] || { printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"; exit 1; }

# ---------------------------------------------------------------- fetch

group "fetch (pinned + hash-verified)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mp-upstream.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Populates $WORK/<key>. A hash mismatch is fatal for the whole run rather than
# one more counted failure: it means the bytes upstream no longer match the pin,
# and continuing would run unreviewed third-party code to produce a verdict
# nobody should trust.
fetch_pinned() {
  local key repo ref path want got dest
  key="$1"
  repo="$(p ".files[\"$key\"].repo")"
  ref="$(p  ".files[\"$key\"].ref")"
  path="$(p ".files[\"$key\"].path")"
  want="$(p ".files[\"$key\"].sha256")"
  dest="$WORK/$key"

  case "$ref" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      [ "${#ref}" -eq 40 ] || { bad "pin is a full commit SHA: $key" "got '$ref'"; return 1; } ;;
    *) bad "pin is a full commit SHA: $key" "got '$ref' — a mutable ref can be repointed upstream"; return 1 ;;
  esac

  if ! curl -fsSL --retry 2 -o "$dest" "$RAW/$repo/$ref/$path" 2>/dev/null; then
    bad "fetch: $key" "$RAW/$repo/$ref/$path unreachable"
    return 1
  fi

  got="$(sha256_of "$dest")"
  if [ "$got" != "$want" ]; then
    printf '  \033[31mFAIL\033[0m %s\n' "hash: $key"
    printf '       expected %s\n       got      %s\n' "$want" "$got"
    printf '       upstream changed at a pinned SHA, or the pin is wrong.\n'
    printf '       Refresh deliberately: ./tests/upstream.sh --latest\n'
    exit 1
  fi
  ok "$key  ($(p ".files[\"$key\"].repo") @ $(p ".files[\"$key\"].refName"))"
}

FETCHED=1
for key in $(p '.files | keys[]'); do
  fetch_pinned "$key" || FETCHED=0
done

# ---------------------------------------------------------------- cursor

group "cursor — cursor/plugins publication schema"

if [ "$FETCHED" -eq 0 ]; then
  bad "cursor schema validation" "pinned artefacts unavailable"
else
  cat > "$WORK/validate.py" <<'PY'
import json, sys
from jsonschema import Draft7Validator

# ajv with allErrors + ajv-formats is what cursor/plugins' own
# .github/workflows/validate-plugins.yml runs. Draft7Validator with the format
# checker enabled is the closest stdlib-adjacent equivalent: identical treatment
# of additionalProperties/required/pattern, which is what separates a conforming
# manifest from a rejected one, plus the same format assertions.
schema, doc = (json.load(open(p)) for p in sys.argv[1:3])
errors = sorted(
    Draft7Validator(schema, format_checker=Draft7Validator.FORMAT_CHECKER).iter_errors(doc),
    key=lambda e: list(e.path),
)
for e in errors:
    print("%s: %s" % ("/" + "/".join(str(x) for x in e.path), e.message))
sys.exit(1 if errors else 0)
PY

  check_schema() {
    local label="$1" schema="$2" doc="$3" out
    if [ ! -f "$doc" ]; then bad "$label" "$doc missing — run ./build.sh"; return; fi
    if out="$(python3 "$WORK/validate.py" "$WORK/$schema" "$doc" 2>&1)"; then
      ok "$label"
    else
      bad "$label" "$out"
    fi
  }

  check_schema "plugin.json conforms"      cursor-plugin-schema      "$ROOT/dist/cursor/.cursor-plugin/plugin.json"
  check_schema "marketplace.json conforms" cursor-marketplace-schema "$ROOT/.cursor-plugin/marketplace.json"
fi

# ---------------------------------------------------------------- codex

group "codex — openai/codex plugin ingestion validator"

if [ "$FETCHED" -eq 0 ]; then
  bad "codex plugin validation" "pinned artefacts unavailable"
elif out="$(python3 "$WORK/codex-plugin-validator" "$ROOT/dist/codex" 2>&1)"; then
  ok "dist/codex passes validate_plugin.py"
else
  bad "dist/codex passes validate_plugin.py" "$out"
fi

# ---------------------------------------------------------------- claude code

group "claude-code — claude plugin validate --strict"

CC_VERSION="$(p '.clis["claude-code"].version')"
if ! command -v claude >/dev/null 2>&1; then
  printf '  \033[33mskip\033[0m claude CLI not on PATH (CI pins @%s)\n' "$CC_VERSION"
else
  have="$(claude --version 2>/dev/null | awk '{print $1}')"
  if [ "$have" = "$CC_VERSION" ]; then
    ok "CLI version matches the pin ($CC_VERSION)"
  else
    # Not a failure locally: a developer's CLI updates itself. CI installs the
    # pinned version explicitly, so there the two always agree.
    printf '  \033[33mnote\033[0m local claude is %s, pin is %s\n' "${have:-unknown}" "$CC_VERSION"
  fi

  # An empty config dir keeps a developer's real marketplaces and installs out
  # of the run, and proves the check needs no credentials.
  export CLAUDE_CONFIG_DIR="$WORK/claude-config"
  mkdir -p "$CLAUDE_CONFIG_DIR"

  for target in "dist/claude-code" "."; do
    if out="$(claude plugin validate --strict "$ROOT/$target" 2>&1)"; then
      ok "validate --strict: $target"
    else
      bad "validate --strict: $target" "$out"
    fi
  done
fi

# ----------------------------------------------------------------

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
