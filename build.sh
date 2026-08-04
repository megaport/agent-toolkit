#!/usr/bin/env bash
# Render core/ x hosts/ -> dist/
#
#   ./build.sh                       build every host in hosts/
#   ./build.sh claude-code           build one host
#   ./build.sh --check               build into a temp dir and diff against dist/
#   ./build.sh --with-terraform-mcp  fold the opt-in Terraform MCP server into the
#                                    active config instead of emitting
#                                    mcp.optional.json. Needs Docker at runtime, so
#                                    it is deliberately not what CI builds — the
#                                    committed dist/ is always the default output.
#
# dist/ is generated and committed. Never hand-edit it; CI enforces that it
# matches this script's output.
#
# Build-time dependency: jq. (Runtime scripts need only bash/curl plus jq OR
# python3 — see AGENTS.md.)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CORE="$ROOT/core"
HOSTS="$ROOT/hosts"
TOOLKIT="$CORE/toolkit.json"

command -v jq >/dev/null 2>&1 || { echo "build.sh needs jq on PATH" >&2; exit 1; }

OUT="$ROOT/dist"
CHECK=0
WITH_TF=0
WANTED=""

# --help reprints the header comment block above. The range ends on the last `#`
# line, not on `set -euo pipefail` — extend it if you add to the header.
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --with-terraform-mcp) WITH_TF=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *) WANTED="$arg" ;;
  esac
done

if [ "$CHECK" -eq 1 ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/mp-toolkit-check.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$OUT'" EXIT
fi

# --- values from toolkit.json ------------------------------------------------

j() { jq -r "$1" "$TOOLKIT"; }

NAME="$(j '.name')"
VERSION="$(j '.version')"
DOCS_BASE="$(j '.pins.docs_base_url')"
CLI_VERSION="$(j '.pins.megaport_cli_version')"

say() { printf '  %s\n' "$*"; }

# --- templating --------------------------------------------------------------
# Bash parameter expansion, not sed: the Cursor plugin-root expression contains
# ${…:-…} and $HOME, which sed delimiters and & handling would mangle.

render() {
  local content="$1" plugin_root="$2" lib="$3"
  content="${content//\{\{PLUGIN_ROOT\}\}/$plugin_root}"
  content="${content//\{\{LIB\}\}/$lib}"
  content="${content//\{\{VERSION\}\}/$VERSION}"
  content="${content//\{\{CLI_VERSION\}\}/$CLI_VERSION}"
  content="${content//\{\{DOCS_BASE\}\}/$DOCS_BASE}"
  content="${content//\{\{NAME\}\}/$NAME}"
  printf '%s' "$content"
}

render_file() {
  local src="$1" dst="$2" plugin_root="$3" lib="$4" content
  content="$(cat "$src")"
  mkdir -p "$(dirname "$dst")"
  render "$content" "$plugin_root" "$lib" > "$dst"
}

# Drop frontmatter keys the target host does not understand. Operates on
# top-level keys only, preserving block values (e.g. the `paths:` list) that
# belong to a kept key.
filter_frontmatter() {
  local file="$1" allowed="$2"
  awk -v allowed=" $allowed " '
    BEGIN { state = 0 }
    NR == 1 && $0 == "---" { print; state = 1; next }
    state == 1 && $0 == "---" { print; state = 2; next }
    state == 1 {
      if ($0 ~ /^[A-Za-z0-9_-]+:/) {
        key = $0; sub(/:.*$/, "", key)
        keep = (index(allowed, " " key " ") > 0)
      }
      if (keep) print
      next
    }
    { print }
  ' "$file"
}

# Insert a host-specific paragraph immediately after the closing frontmatter
# `---`. Hosts that declare no `.skillPreamble` pass through untouched, so this
# is invisible to every host but the one that needs it. Passed via the
# environment, not `awk -v`, because -v applies backslash-escape processing to
# the value and a preamble is prose.
inject_preamble() {
  [ -n "$1" ] || { cat; return; }
  MP_PREAMBLE="$1" awk '
    { print }
    /^---$/ { if (++seen == 2) printf "\n%s\n", ENVIRON["MP_PREAMBLE"] }
  '
}

# --- per-host build ----------------------------------------------------------

build_host() {
  local hdir="$1" host hjson dest plugin_root lib
  hjson="$hdir/host.json"
  host="$(jq -r '.id' "$hjson")"
  dest="$OUT/$host"

  hj() { jq -r "$1" "$hjson"; }

  plugin_root="$(hj '.pluginRootExpr')"
  lib="$plugin_root/lib"

  printf '%s (%s)\n' "$host" "$(hj '.displayName')"
  rm -rf "$dest"
  mkdir -p "$dest"

  # 1. runtime library + hooks, tokens rendered
  local f
  for f in "$CORE"/lib/*.sh; do
    render_file "$f" "$dest/lib/$(basename "$f")" "$plugin_root" "$lib"
    chmod +x "$dest/lib/$(basename "$f")"
  done
  for f in "$CORE"/hooks/*.sh; do
    render_file "$f" "$dest/hooks/$(basename "$f")" "$plugin_root" "$lib"
    chmod +x "$dest/hooks/$(basename "$f")"
  done
  say "lib/ hooks/"

  # 2. toolkit.json — the runtime reads pins, safety policy and the allowlist
  #    from here. Editorial $comment keys are stripped.
  jq 'walk(if type == "object" then with_entries(select(.key | startswith("$") | not)) else . end)' \
    "$TOOLKIT" > "$dest/toolkit.json"

  # 3. skills
  local skills_dir skill_names skill fm preamble
  skills_dir="$(hj '.skillsDir')"
  fm="$(hj '.frontmatterKeys | join(" ")')"
  # Optional per-host note prepended to every skill body — see inject_preamble.
  # It goes in before render(), so it may use the same {{TOKEN}} vocabulary.
  preamble="$(hj '.skillPreamble // empty')"
  skill_names="$(j '.skills[]')"
  while IFS= read -r skill; do
    [ -n "$skill" ] || continue
    [ -f "$CORE/skills/$skill/SKILL.md" ] \
      || { echo "toolkit.json lists skill '$skill' but core/skills/$skill/SKILL.md does not exist" >&2; exit 1; }
    mkdir -p "$dest/$skills_dir/$skill"
    filter_frontmatter "$CORE/skills/$skill/SKILL.md" "$fm" \
      | inject_preamble "$preamble" \
      | { content="$(cat)"; render "$content" "$plugin_root" "$lib"; } \
      > "$dest/$skills_dir/$skill/SKILL.md"
    # Copy any supporting files the skill ships alongside SKILL.md.
    find "$CORE/skills/$skill" -type f ! -name SKILL.md -print 2>/dev/null | while IFS= read -r extra; do
      rel="${extra#"$CORE/skills/$skill/"}"
      mkdir -p "$(dirname "$dest/$skills_dir/$skill/$rel")"
      cp "$extra" "$dest/$skills_dir/$skill/$rel"
    done
  done <<EOF
$skill_names
EOF
  say "$skills_dir/ ($(printf '%s' "$skill_names" | grep -c .) skills)"

  # 4. MCP configuration.
  #    Servers flagged `optional` are written to a separate file rather than the
  #    active config — the Terraform MCP server needs Docker and must not break
  #    the install for users who don't have it.
  #    `--with-terraform-mcp` folds them into the active set instead (same $-key
  #    and `optional`-key stripping), which leaves nothing optional, so
  #    mcp.optional.json is then not emitted at all. CI never passes the flag:
  #    the committed dist/ is byte-for-byte the default build.
  local active optional mcp_mode mcp_file
  active="$(jq '.mcpServers | with_entries(select(.value.optional != true))
                | walk(if type=="object" then with_entries(select(.key|startswith("$")|not)) else . end)' "$TOOLKIT")"
  optional="$(jq '.mcpServers | with_entries(select(.value.optional == true))
                  | walk(if type=="object" then with_entries(select(.key|startswith("$")|not) | select(.key != "optional")) else . end)' "$TOOLKIT")"

  if [ "$WITH_TF" -eq 1 ]; then
    active="$(printf '%s' "$active" | jq --argjson o "$optional" '. + $o')"
    optional='{}'
  fi

  #    Standalone MCP files carry the standard `{"mcpServers": …}` wrapper.
  #    Codex's publication validator rejects unknown top-level keys, so a bare
  #    server map is read as three unknown keys and fails ingestion; the same
  #    wrapper is Cursor's documented mcp.json shape, and it is what a user
  #    pastes mcp.optional.json into. Inline mode (Claude Code) embeds the bare
  #    map under the manifest's own `mcpServers` key instead — see step 6.
  mcp_mode="$(hj '.mcp.mode')"
  if [ "$(printf '%s' "$optional" | jq 'length')" -gt 0 ]; then
    printf '%s' "$optional" | jq '{mcpServers: .}' > "$dest/mcp.optional.json"
  fi

  if [ "$mcp_mode" = "file" ]; then
    mcp_file="$(hj '.mcp.file')"
    mkdir -p "$(dirname "$dest/$mcp_file")"
    printf '%s' "$active" | jq '{mcpServers: .}' > "$dest/$mcp_file"
    say "$mcp_file"
  fi

  # 5. hooks config, in the host's dialect
  local hooks_file dialect hooks_json matcher script
  hooks_file="$(hj '.hooks.file')"
  dialect="$(hj '.hooks.dialect')"
  matcher="$(j '.hooks[0].matcher')"
  script="$plugin_root/hooks/confirm-mutation.sh --dialect $dialect"

  case "$dialect" in
    cursor)
      hooks_json="$(jq -n --arg cmd "$script" --arg ev "$(hj '.hooks.event')" '
        {version: 1, hooks: {($ev): [{type: "command", command: $cmd, timeout: 15, failClosed: true}]}}')"
      ;;
    *)
      hooks_json="$(jq -n --arg cmd "$script" --arg m "$matcher" '
        {hooks: {PreToolUse: [{matcher: $m, hooks: [{type: "command", command: $cmd}]}]}}')"
      ;;
  esac
  mkdir -p "$(dirname "$dest/$hooks_file")"
  printf '%s\n' "$hooks_json" > "$dest/$hooks_file"
  say "$hooks_file (dialect: $dialect)"

  # 6. plugin manifest. The shape is host-driven via `.manifest.flavour`;
  #    absent means the default shape, which is what every host but Codex takes.
  local plugin_dir manifest manifest_flavour
  plugin_dir="$(hj '.pluginDir')"
  manifest_flavour="$(hj '.manifest.flavour // "default"')"
  mkdir -p "$dest/$plugin_dir"

  manifest="$(jq -n \
    --slurpfile t "$TOOLKIT" \
    '{
      name:        $t[0].name,
      version:     $t[0].version,
      description: $t[0].description,
      author:      $t[0].author,
      homepage:    $t[0].homepage,
      repository:  $t[0].repository,
      license:     $t[0].license,
      keywords:    $t[0].keywords
    }')"

  case "$manifest_flavour" in
    codex)
      # Codex's runtime loader is lenient; its publication validator is not.
      # `skills` must be a single string normalising to the skills directory,
      # and `interface` is mandatory. Editorial $-keys are stripped from the
      # interface block on the way through.
      [ "$(j '.interface | type')" = "object" ] \
        || { echo "host $host uses manifest flavour 'codex' but core/toolkit.json has no .interface object" >&2; exit 1; }
      manifest="$(printf '%s' "$manifest" | jq \
        --slurpfile t "$TOOLKIT" --arg skillsdir "$skills_dir" '. + {
          skills:    ("./" + $skillsdir),
          interface: ($t[0].interface | with_entries(select(.key | startswith("$") | not)))
        }')"
      ;;
    *)
      manifest="$(printf '%s' "$manifest" | jq \
        --slurpfile t "$TOOLKIT" --arg skillsdir "$skills_dir" '. + {
          skills: ($t[0].skills | map("./" + $skillsdir + "/" + .))
        }')"
      ;;
  esac

  if [ "$mcp_mode" = "inline" ]; then
    manifest="$(printf '%s' "$manifest" | jq --argjson m "$active" '.mcpServers = $m')"
  else
    local key; key="$(hj '.mcp.manifestKey // empty')"
    [ -n "$key" ] && manifest="$(printf '%s' "$manifest" | jq --arg f "./$(hj '.mcp.file')" --arg k "$key" '.[$k] = $f')"
  fi

  # The hooks file is always written (step 5); naming it in the manifest is
  # optional and per-host. The codex flavour deliberately does not name it: its
  # validator allows a fixed key set that has no `hooks` in it, and its loader
  # defaults to hooks/hooks.json (DEFAULT_HOOKS_CONFIG_FILE,
  # codex-rs/core-plugins/src/loader.rs) — which is where step 5 already put it.
  local hkey; hkey="$(hj '.hooks.manifestKey // empty')"
  if [ -n "$hkey" ]; then
    manifest="$(printf '%s' "$manifest" | jq --arg f "./$hooks_file" --arg k "$hkey" '.[$k] = $f')"
  elif [ "$dialect" != "cursor" ] && [ "$manifest_flavour" != "codex" ]; then
    manifest="$(printf '%s' "$manifest" | jq --arg f "./$hooks_file" '.hooks = $f')"
  fi

  printf '%s\n' "$manifest" > "$dest/$plugin_dir/plugin.json"
  say "$plugin_dir/plugin.json"

  # 7. README for the generated tree, so nobody edits it by mistake
  {
    printf '# %s — %s build\n\n' "$NAME" "$(hj '.displayName')"
    printf 'GENERATED FILE TREE. Do not edit.\n\n'
    printf 'Source: `core/` + `hosts/%s/host.json`. Regenerate with `./build.sh %s`.\n\n' "$host" "$host"
    printf '## Install\n\n```\n'
    hj '.install[]'
    printf '```\n'
    if [ -f "$dest/mcp.optional.json" ]; then
      printf '\n## Optional MCP servers\n\nSee `mcp.optional.json`. Not enabled by default because it requires Docker.\n'
    fi
  } > "$dest/README.md"

  # 8. root marketplace entry for this host
  build_marketplace "$hjson" "$host"
}

build_marketplace() {
  local hjson="$1" host="$2" mfile flavour target
  mfile="$(jq -r '.marketplace.file' "$hjson")"
  flavour="$(jq -r '.marketplace.flavour // "default"' "$hjson")"
  target="$OUT/../$mfile"
  [ "$CHECK" -eq 1 ] && target="$OUT/_marketplace/$mfile"
  mkdir -p "$(dirname "$target")"

  case "$flavour" in
    codex)
      jq -n --slurpfile t "$TOOLKIT" --arg path "./dist/$host" '{
        name: "megaport",
        interface: { displayName: "Megaport" },
        plugins: [{
          name: $t[0].name,
          description: $t[0].description,
          category: "infrastructure",
          source: { source: "local", path: $path }
        }]
      }' > "$target"
      ;;
    *)
      jq -n --slurpfile t "$TOOLKIT" --arg path "./dist/$host" '{
        name: "megaport",
        description: "Official Megaport plugins for AI coding assistants",
        owner: $t[0].author,
        plugins: [{
          name: $t[0].name,
          source: $path,
          description: $t[0].description,
          version: $t[0].version,
          author: $t[0].author
        }]
      }' > "$target"
      ;;
  esac
  say "$mfile"
}

# --- drive -------------------------------------------------------------------

printf 'Building %s v%s\n\n' "$NAME" "$VERSION"

found=0
for hdir in "$HOSTS"/*/; do
  [ -f "$hdir/host.json" ] || continue
  hid="$(jq -r '.id' "$hdir/host.json")"
  if [ -n "$WANTED" ] && [ "$WANTED" != "$hid" ]; then continue; fi
  build_host "${hdir%/}"
  found=$((found + 1))
  printf '\n'
done

[ "$found" -gt 0 ] || { echo "no hosts matched${WANTED:+ '$WANTED'}" >&2; exit 1; }

if [ "$CHECK" -eq 1 ]; then
  echo "Comparing generated output against dist/ ..."
  for hdir in "$HOSTS"/*/; do
    [ -f "$hdir/host.json" ] || continue
    hid="$(jq -r '.id' "$hdir/host.json")"
    if [ -n "$WANTED" ] && [ "$WANTED" != "$hid" ]; then continue; fi
    diff -ru "$ROOT/dist/$hid" "$OUT/$hid" \
      || { echo "dist/$hid is out of date — run ./build.sh and commit the result" >&2; exit 1; }
    # The marketplace entry is generated too, it just lands outside dist/. Check
    # mode diverts it to $OUT/_marketplace so the real one is not clobbered —
    # which also means it goes unchecked unless it is compared here explicitly.
    mfile="$(jq -r '.marketplace.file' "$hdir/host.json")"
    diff -u "$ROOT/$mfile" "$OUT/_marketplace/$mfile" \
      || { echo "$mfile is out of date — run ./build.sh and commit the result" >&2; exit 1; }
  done
  echo "dist/ and the marketplace manifests are up to date."
else
  printf 'Built %s host(s) into dist/\n' "$found"
fi
