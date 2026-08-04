#!/usr/bin/env bash
# Test suite for the Megaport Agent Toolkit.
#
#   ./tests/run.sh            everything except network tests
#   ./tests/run.sh --network  also hit docs.megaport.com and the TF registry
#
# Groups:
#   lint       shellcheck (if installed) + bash -n on every script
#   schema     toolkit.json / host.json well-formed and internally consistent
#   allowlist  no script may reach a host absent from allowedHosts
#   workflows  every GitHub Action is pinned to a full commit SHA
#   hooks      the safety gate, in both dialects, including fail-closed paths
#   wrapper    mp-cli.sh refuses to forward credential-leaking CLI flags
#   build      dist/ matches ./build.sh output
#   network    live retrieval smoke tests

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/core"
NETWORK=0
[ "${1:-}" = "--network" ] && NETWORK=1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- lint

group "lint"

# One list, two loops. They were maintained separately and drifted: this file
# was parse-checked but never linted, so anything added to it went unshellchecked.
SCRIPTS=("$ROOT"/build.sh "$ROOT"/tests/run.sh "$CORE"/lib/*.sh "$CORE"/hooks/*.sh)

for f in "${SCRIPTS[@]}"; do
  if bash -n "$f" 2>/dev/null; then ok "parses: ${f#"$ROOT"/}"; else bad "parses: ${f#"$ROOT"/}" "$(bash -n "$f" 2>&1)"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  for f in "${SCRIPTS[@]}"; do
    if out="$(shellcheck -S warning -e SC1091 "$f" 2>&1)"; then
      ok "shellcheck: ${f#"$ROOT"/}"
    else
      bad "shellcheck: ${f#"$ROOT"/}" "$out"
    fi
  done
else
  printf '  \033[33mskip\033[0m shellcheck not installed\n'
fi

# ---------------------------------------------------------------- schema

group "schema"

if jq empty "$CORE/toolkit.json" 2>/dev/null; then ok "toolkit.json is valid JSON"; else bad "toolkit.json is valid JSON"; fi

for s in $(jq -r '.skills[]' "$CORE/toolkit.json"); do
  if [ -f "$CORE/skills/$s/SKILL.md" ]; then ok "skill exists: $s"; else bad "skill exists: $s" "core/skills/$s/SKILL.md missing"; fi
  # Frontmatter must carry name + description or no host will ever load it.
  if head -20 "$CORE/skills/$s/SKILL.md" 2>/dev/null | grep -q '^name:' \
  && head -20 "$CORE/skills/$s/SKILL.md" 2>/dev/null | grep -q '^description:'; then
    ok "frontmatter: $s"
  else
    bad "frontmatter: $s" "needs both name: and description:"
  fi
done

for h in "$ROOT"/hosts/*/host.json; do
  hid="$(jq -r '.id // empty' "$h" 2>/dev/null)"
  if [ -n "$hid" ]; then ok "host.json valid: $hid"; else bad "host.json valid: ${h#"$ROOT"/}"; fi
  for k in pluginDir pluginRootExpr skillsDir frontmatterKeys mcp hooks marketplace; do
    if [ "$(jq -r "has(\"$k\")" "$h")" = "true" ]; then :; else bad "host $hid has .$k"; fi
  done
  ok "host $hid declares all required keys"
done

# Tokens used in skills must be ones build.sh knows how to render.
KNOWN='PLUGIN_ROOT|LIB|VERSION|CLI_VERSION|DOCS_BASE|NAME'
unknown="$(grep -rhoE '\{\{[A-Z_]+\}\}' "$CORE/skills" 2>/dev/null | sort -u | grep -vE "\{\{($KNOWN)\}\}" || true)"
if [ -z "$unknown" ]; then ok "no unknown template tokens"; else bad "no unknown template tokens" "$unknown"; fi

# No unrendered token may survive into dist/.
if [ -d "$ROOT/dist" ]; then
  leaked="$(grep -rlE '\{\{[A-Z_]+\}\}' "$ROOT/dist" 2>/dev/null || true)"
  if [ -z "$leaked" ]; then ok "no unrendered tokens in dist/"; else bad "no unrendered tokens in dist/" "$leaked"; fi
fi

# ---------------------------------------------------------------- allowlist

group "allowlist"

allowed="$(jq -r '.allowedHosts.hosts[]' "$CORE/toolkit.json")"
found_hosts="$(grep -rhoE 'https://[a-zA-Z0-9.-]+' "$CORE/lib" "$CORE/hooks" 2>/dev/null \
               | sed 's#https://##' | sort -u || true)"
violation=0
for host in $found_hosts; do
  if printf '%s\n' "$allowed" | grep -Fxq "$host"; then :; else
    bad "outbound host allowlisted: $host" "add it to core/toolkit.json .allowedHosts.hosts, or remove the call"
    violation=1
  fi
done
[ "$violation" -eq 0 ] && ok "every outbound host in core/ is allowlisted"

# ---------------------------------------------------------------- workflows

group "workflows"

# GitHub Actions are the only third-party code this repo executes, and it runs
# on a runner holding a token. A mutable tag (@v7) can be repointed at any
# commit by whoever controls the upstream repo; a 40-hex SHA cannot. Same
# reasoning as the outbound-host allowlist above, different surface.
WF="$ROOT/.github/workflows"
if [ ! -d "$WF" ]; then
  printf '  \033[33mskip\033[0m no .github/workflows\n'
else
  uses_lines="$(grep -rhE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]]' "$WF" 2>/dev/null || true)"
  unpinned=""; unlabelled=""; checked=0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ref="${line#*uses:}"
    comment=""
    case "$ref" in *\#*) comment="${ref#*#}" ;; esac
    ref="${ref%%#*}"
    ref="$(printf '%s' "$ref" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')"
    case "$ref" in ./*) continue ;; esac   # action defined in this repo
    checked=$((checked + 1))
    if printf '%s' "${ref##*@}" | grep -qE '^[0-9a-f]{40}$'; then
      # dependabot writes `# vX.Y.Z` next to the SHA it bumps. Without it the
      # pin is 40 opaque characters and nobody can tell what version they run.
      printf '%s' "$comment" | grep -qE 'v[0-9]' || unlabelled="$unlabelled $ref"
    else
      unpinned="$unpinned $ref"
    fi
  done <<< "$uses_lines"

  if [ "$checked" -eq 0 ]; then
    printf '  \033[33mskip\033[0m no third-party `uses:` steps\n'
  else
    if [ -z "$unpinned" ]; then
      ok "actions pinned to a full commit SHA ($checked checked)"
    else
      bad "actions pinned to a full commit SHA" \
          "mutable ref(s):$unpinned — resolve with: gh api repos/OWNER/REPO/commits/TAG --jq .sha"
    fi
    if [ -z "$unlabelled" ]; then
      ok "every pin records its version in a trailing comment"
    else
      bad "every pin records its version in a trailing comment" \
          "missing a '# vX.Y.Z' comment:$unlabelled"
    fi
  fi
fi

# ---------------------------------------------------------------- hooks

group "hooks"

HOOK="$ROOT/dist/claude-code/hooks/confirm-mutation.sh"
if [ ! -x "$HOOK" ]; then
  bad "hook built" "run ./build.sh first"
else
  # decision <dialect> <command> -> the permission decision, or "exit:<code>"
  decision() {
    local dialect="$1" cmd="$2" payload out rc
    if [ "$dialect" = "cursor" ]; then
      payload="$(jq -n --arg c "$cmd" '{hook_event_name:"beforeShellExecution",command:$c,cwd:"/tmp"}')"
    else
      payload="$(jq -n --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')"
    fi
    out="$(printf '%s' "$payload" | "$HOOK" --dialect "$dialect" 2>/dev/null)"; rc=$?
    if [ "$dialect" = "cursor" ]; then
      printf '%s/%s' "$(printf '%s' "$out" | jq -r '.permission // "none"')" "$rc"
    else
      printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "none"'
    fi
  }

  # Same thing for a payload `decision` could not produce: jq -n only ever emits
  # well-formed JSON, and the fail-closed input paths need the malformed kind.
  raw_decision() {
    printf '%s' "$1" | "$HOOK" --dialect pretooluse 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "none"'
  }

  expect() {
    local label="$1" want="$2" got="$3"
    [ "$got" = "$want" ] && ok "$label" || bad "$label" "expected '$want', got '$got'"
  }

  # Real megaport-cli 1.0.0-beta.2 grammar: `<group> <verb>`.
  expect "allow: ports list"                     allow "$(decision pretooluse 'megaport-cli ports list')"
  expect "allow: vxc list"                       allow "$(decision pretooluse 'megaport-cli vxc list')"
  expect "allow: mcr get <uid>"                  allow "$(decision pretooluse 'megaport-cli mcr get abc-123')"
  expect "allow: locations list-countries"       allow "$(decision pretooluse 'megaport-cli locations list-countries')"
  expect "allow: ports list-tags (prefix rule)"  allow "$(decision pretooluse 'megaport-cli ports list-tags xyz')"
  expect "allow: mcr get-prefix-filter-list"     allow "$(decision pretooluse 'megaport-cli mcr get-prefix-filter-list a b')"
  expect "allow: ports validate-lag"             allow "$(decision pretooluse 'megaport-cli ports validate-lag --file x')"
  expect "allow: top-level whoami"               allow "$(decision pretooluse 'megaport-cli whoami')"
  expect "allow: top-level version"              allow "$(decision pretooluse 'megaport-cli version')"
  expect "allow: bare megaport-cli"              allow "$(decision pretooluse 'megaport-cli')"
  expect "allow: unrelated command"              allow "$(decision pretooluse 'echo hello world')"

  # mp-cli.sh is the wrapper every skill actually invokes, by absolute path out
  # of the plugin's lib/. If it is not guarded exactly like the real binary, the
  # documented call path walks straight past the hook.
  expect "allow: wrapper ports list"             allow "$(decision pretooluse 'mp-cli.sh ports list')"
  expect "allow: wrapper by path"                allow "$(decision pretooluse '/path/to/lib/mp-cli.sh locations list')"
  expect "allow: wrapper --install"              allow "$(decision pretooluse 'mp-cli.sh --install')"
  expect "allow: wrapper --version"              allow "$(decision pretooluse 'mp-cli.sh --version')"
  expect "ask: wrapper ports delete"             ask "$(decision pretooluse 'mp-cli.sh ports delete abc')"
  expect "ask: wrapper by plugin path vxc buy"   ask "$(decision pretooluse '/home/u/.claude/plugins/x/lib/mp-cli.sh vxc buy')"

  # Global value-flags must not be mistaken for the verb.
  expect "allow: --output json before verb"      allow "$(decision pretooluse 'megaport-cli --output json ports list')"
  expect "allow: --output=json before verb"      allow "$(decision pretooluse 'megaport-cli --output=json ports list')"
  expect "allow: --env staging before verb"      allow "$(decision pretooluse 'megaport-cli --env staging vxc list')"
  expect "allow: --query .name before verb"      allow "$(decision pretooluse 'megaport-cli --query .name ports list')"
  expect "allow: --timeout 30s before verb"      allow "$(decision pretooluse 'megaport-cli --timeout 30s ports list')"

  # ...and the flag's value must not be read as one either: `--query list` would
  # otherwise put a read-only 'list' in the window and clear the delete behind it.
  expect "ask: value-flag value laundering"      ask "$(decision pretooluse 'megaport-cli --query list ports delete abc')"

  # Flags that repoint the API or token endpoint, or spill auth headers to
  # stderr, are disqualifying whatever the verb says.
  expect "ask: --log-http with a read verb"      ask "$(decision pretooluse 'megaport-cli --log-http ports list')"
  expect "ask: --base-url with a read verb"      ask "$(decision pretooluse 'megaport-cli --base-url http://localhost:9 ports list')"
  expect "ask: --base-url=… with a read verb"    ask "$(decision pretooluse 'megaport-cli --base-url=http://localhost:9 ports list')"
  expect "ask: --token-url with a read verb"     ask "$(decision pretooluse 'megaport-cli --token-url http://localhost:9 ports list')"

  # --help can never mutate; agents explore with it constantly.
  expect "allow: group --help"                   allow "$(decision pretooluse 'megaport-cli ports --help')"
  expect "allow: mutating verb with --help"      allow "$(decision pretooluse 'megaport-cli vxc buy --help')"

  # ...but a --help inside a comment is not passed to anything. The delete runs.
  expect "ask: --help commented out"             ask "$(decision pretooluse 'megaport-cli ports delete abc # --help')"
  expect "ask: --help commented out, no space"   ask "$(decision pretooluse 'megaport-cli ports delete abc #--help')"

  # ...and `--` ends flag parsing, so a help flag behind it is an argument the
  # verb receives, not a request for help. The delete runs there too.
  expect "ask: --help behind -- terminator"      ask "$(decision pretooluse 'megaport-cli ports delete abc -- --help')"
  expect "ask: -h behind -- terminator"          ask "$(decision pretooluse 'megaport-cli ports delete abc -- -h')"
  expect "allow: read verb with -- terminator"   allow "$(decision pretooluse 'megaport-cli ports list -- --help')"

  # Terraform reads
  expect "allow: terraform plan"                 allow "$(decision pretooluse 'terraform plan')"
  expect "allow: terraform -chdir plan"          allow "$(decision pretooluse 'terraform -chdir=infra plan')"
  expect "allow: terraform validate"             allow "$(decision pretooluse 'terraform validate')"

  # Mutations escalate
  expect "ask: vxc buy"                          ask "$(decision pretooluse 'megaport-cli vxc buy --interactive')"
  expect "ask: ports delete"                     ask "$(decision pretooluse 'megaport-cli ports delete abc123')"
  expect "ask: ports update"                     ask "$(decision pretooluse 'megaport-cli ports update abc --name x')"
  expect "ask: ports lock"                       ask "$(decision pretooluse 'megaport-cli ports lock abc123')"
  expect "ask: ports restore"                    ask "$(decision pretooluse 'megaport-cli ports restore abc123')"
  expect "ask: config set-default"               ask "$(decision pretooluse 'megaport-cli config set-default env prod')"
  expect "ask: apply from file"                  ask "$(decision pretooluse 'megaport-cli apply -f topology.yaml')"
  expect "ask: mcr add-ipsec-addon"              ask "$(decision pretooluse 'megaport-cli mcr add-ipsec-addon abc')"
  expect "ask: terraform apply"                  ask "$(decision pretooluse 'terraform apply -auto-approve')"
  expect "ask: terraform destroy"                ask "$(decision pretooluse 'terraform destroy')"
  expect "ask: terraform state rm"               ask "$(decision pretooluse 'terraform state rm megaport_vxc.a')"

  # Fail-closed on a verb this version has never heard of.
  expect "ask: unknown future verb"              ask "$(decision pretooluse 'megaport-cli ports provision everything')"

  # A read verb appearing as an argument must not launder a mutating verb.
  expect "ask: buy with 'list' as an argument"   ask "$(decision pretooluse 'megaport-cli vxc buy --from-file list')"

  # Compound commands: the safe half must not mask the dangerous half.
  expect "ask: compound read-then-delete"        ask "$(decision pretooluse 'megaport-cli ports list && megaport-cli ports delete x')"
  expect "ask: semicolon-separated"              ask "$(decision pretooluse 'megaport-cli ports list; megaport-cli ports delete x')"
  expect "ask: piped mutation"                   ask "$(decision pretooluse 'echo y | megaport-cli ports delete x')"
  expect "ask: absolute path invocation"         ask "$(decision pretooluse '/usr/local/bin/megaport-cli ports delete x')"

  # A newline separates commands exactly like `;`. Folded into one segment, the
  # read-only line would vouch for the mutating one.
  expect "ask: newline-separated"                ask "$(decision pretooluse $'megaport-cli ports list\nmegaport-cli ports delete x')"
  expect "allow: newline-separated reads"        allow "$(decision pretooluse $'megaport-cli ports list\nmegaport-cli vxc list')"

  # Two invocations in one segment are judged one at a time; the first cannot
  # clear the second.
  expect "ask: two invocations, one segment"     ask "$(decision pretooluse 'megaport-cli ports list megaport-cli ports delete x')"

  # Quoting hides the binary from a naive token scan: `bash -c 'megaport-cli …'`
  # tokenises as `'megaport-cli`.
  expect "ask: quoted bash -c invocation"        ask "$(decision pretooluse "bash -c 'megaport-cli ports delete abc'")"
  expect "ask: double-quoted bash -c"            ask "$(decision pretooluse 'bash -c "megaport-cli ports delete abc"')"

  # Command substitution puts the name in a token we cannot resolve to an
  # invocation. Unclassifiable is not the same as safe.
  expect "ask: command substitution"             ask "$(decision pretooluse 'echo "$(megaport-cli ports delete x)"')"
  expect "ask: backticked invocation"            ask "$(decision pretooluse 'echo `megaport-cli ports delete x`')"

  # ...but a guarded name that is merely part of a filename cannot run anything,
  # and escalating on those would train users to switch the hook off.
  expect "allow: terraform.tfvars is a file"     allow "$(decision pretooluse 'cat terraform.tfvars')"
  expect "allow: terraform/ is a directory"      allow "$(decision pretooluse 'git add terraform/main.tf')"

  # Case-insensitive filesystems (macOS, Windows) execute `MEGAPORT-CLI` as the
  # real binary, so binary-name matching folds case. Verbs stay exact: cobra
  # subcommands are case-sensitive, so an uppercase verb escalating is the
  # noisy-but-safe direction.
  expect "ask: uppercase binary name"            ask "$(decision pretooluse 'MEGAPORT-CLI ports delete x')"
  expect "ask: mixed-case terraform apply"       ask "$(decision pretooluse 'Terraform Apply')"
  expect "allow: mixed-case binary, read verb"   allow "$(decision pretooluse 'Megaport-CLI ports list')"
  expect "allow: mixed-case file name"           allow "$(decision pretooluse 'cat Terraform.tfvars')"

  # cursor dialect: deny carries exit code 2, allow carries 0
  expect "cursor allow: ports list"              "allow/0" "$(decision cursor 'megaport-cli ports list')"
  expect "cursor deny: ports delete"             "deny/2"  "$(decision cursor 'megaport-cli ports delete x')"
  expect "cursor deny: wrapper ports delete"     "deny/2"  "$(decision cursor 'mp-cli.sh ports delete x')"
  expect "cursor deny: terraform apply"          "deny/2"  "$(decision cursor 'terraform apply')"

  # The cursor denial must not teach the agent a self-approval ritual. Nothing
  # reads MEGAPORT_CONFIRM, and an agent-settable bypass would defeat the gate.
  cursor_msg="$(jq -n '{hook_event_name:"beforeShellExecution",command:"megaport-cli ports delete x",cwd:"/tmp"}' \
                | "$HOOK" --dialect cursor 2>/dev/null | jq -r '.agent_message // ""')"
  if printf '%s' "$cursor_msg" | grep -q 'MEGAPORT_CONFIRM'; then
    bad "cursor denial advertises no bypass" "agent_message still names an override variable"
  else
    ok "cursor denial advertises no bypass"
  fi

  # A payload the hook cannot read is a command it cannot check. This hook only
  # ever fires on shell tools, so that has to escalate, not wave through.
  expect "ask: empty payload"                    ask "$(raw_decision '')"
  expect "ask: malformed payload"                ask "$(raw_decision 'not json')"
  expect "ask: payload with no command"          ask "$(raw_decision '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{}}')"

  # fail-closed when the policy file is unreadable
  tmp="$(mktemp -d)"; cp "$HOOK" "$tmp/"; mkdir -p "$tmp/x"
  got="$(printf '%s' "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"megaport-cli ports delete x"}}')" \
        | "$tmp/confirm-mutation.sh" --dialect pretooluse 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "none"')"
  expect "ask: missing toolkit.json fails closed" ask "$got"
  rm -rf "$tmp"

  # ...and when it is present but corrupt, which is the quieter failure: every
  # policy lookup returns empty, so nothing is guarded and everything is allowed.
  tmp="$(mktemp -d)"; mkdir -p "$tmp/hooks"; cp "$HOOK" "$tmp/hooks/"
  printf '{invalid' > "$tmp/toolkit.json"
  corrupt_decision() {
    jq -n --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' \
      | "$tmp/hooks/confirm-mutation.sh" --dialect pretooluse 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecision // "none"'
  }
  expect "ask: corrupt toolkit.json fails closed" ask "$(corrupt_decision 'megaport-cli ports delete x')"
  expect "ask: corrupt toolkit.json guards wrapper" ask "$(corrupt_decision 'mp-cli.sh ports list')"
  expect "allow: corrupt toolkit.json, unrelated" allow "$(corrupt_decision 'echo hello world')"
  rm -rf "$tmp"

  # The hook must reach the same verdicts with python3 when jq is absent
  # (AGENTS.md: runtime scripts may assume either, never both).
  nojq="$(mktemp -d)"
  for t in bash cat sed awk grep tr dirname head python3; do
    # type -P, not command -v: a shell function shadowing `grep` would otherwise
    # produce a symlink to nothing and the whole group would fail spuriously.
    p="$(type -P "$t" 2>/dev/null)" && ln -s "$p" "$nojq/$t"
  done
  if [ -x "$nojq/python3" ] && [ -x "$nojq/awk" ] && [ -x "$nojq/grep" ]; then
    nojq_decision() {
      jq -n --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' \
        | PATH="$nojq" "$HOOK" --dialect pretooluse 2>/dev/null \
        | jq -r '.hookSpecificOutput.permissionDecision // "none"'
    }
    expect "allow: ports list (python3, no jq)"  allow "$(nojq_decision 'megaport-cli ports list')"
    expect "ask: ports delete (python3, no jq)"  ask "$(nojq_decision 'megaport-cli ports delete x')"
    expect "ask: --log-http (python3, no jq)"    ask "$(nojq_decision 'megaport-cli --log-http ports list')"
  else
    printf '  \033[33mskip\033[0m python3 fallback (need python3 + awk + grep on PATH)\n'
  fi
  rm -rf "$nojq"
fi

# ---------------------------------------------------------------- wrapper

group "wrapper"

# The hook is the control; the wrapper is the convenience layer that must not be
# a way around it. These run offline: MEGAPORT_CLI_BIN short-circuits the
# download, so what is under test is argument handling and nothing else.

W="$ROOT/dist/claude-code/lib/mp-cli.sh"
if [ ! -x "$W" ]; then
  bad "wrapper built" "run ./build.sh first"
else
  stub="$(mktemp -d)"
  printf '#!/bin/sh\nprintf "STUB %%s\\n" "$*"\n' > "$stub/megaport-cli"
  chmod +x "$stub/megaport-cli"

  # refuses LABEL PATTERN args... — the wrapper must exit non-zero and say why.
  refuses() {
    local label="$1" pattern="$2"; shift 2
    local out rc
    out="$(MEGAPORT_CLI_BIN="$stub/megaport-cli" "$W" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      bad "$label" "the wrapper forwarded the arguments instead of refusing: $out"
    elif printf '%s' "$out" | grep -qE -- "$pattern"; then
      ok "$label"
    else
      bad "$label" "refusal did not match /$pattern/: $out"
    fi
  }

  eq() {
    local label="$1" want="$2" got="$3"
    [ "$got" = "$want" ] && ok "$label" || bad "$label" "expected '$want', got '$got'"
  }

  # --log-http spills auth headers into the transcript; --base-url/--token-url
  # send the credentials themselves somewhere else. Both spellings the CLI
  # accepts have to be caught, and the refusal has to name the escape hatch —
  # a control nobody can find a way past gets switched off wholesale instead.
  refuses "refuses --log-http"                   '--log-http'  --log-http ports list
  refuses "refusal names the override variable"  'MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS=1' --log-http ports list
  refuses "refuses --base-url <url>"             '--base-url'  --base-url http://127.0.0.1:9 ports list
  refuses "refuses --base-url=<url>"             '--base-url'  -- --base-url=http://127.0.0.1:9 ports list
  refuses "refuses --token-url"                  '--token-url' --token-url http://127.0.0.1:9 ports list
  # --system execs a CLI from PATH instead of the cached one. Same flags, same
  # credentials, so it cannot be the unguarded door.
  refuses "refuses on the --system path"         '--log-http'  --system --log-http ports list

  eq "safe arguments pass through" "STUB ports list" \
     "$(MEGAPORT_CLI_BIN="$stub/megaport-cli" "$W" ports list 2>/dev/null)"

  # The override exists for a human who has read the refusal and meant it.
  eq "override forwards the flag" "STUB --log-http ports list" \
     "$(MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS=1 MEGAPORT_CLI_BIN="$stub/megaport-cli" "$W" --log-http ports list 2>/dev/null)"

  # The flag list is policy read from toolkit.json. A corrupt file returns empty
  # for every query, which would leave nothing to match and forward everything —
  # the same quiet failure the hook guards against, on the other side of it.
  corrupt="$(mktemp -d)"; mkdir -p "$corrupt/lib"
  cp "$ROOT/dist/claude-code/lib/common.sh" "$ROOT/dist/claude-code/lib/mp-cli.sh" "$corrupt/lib/"
  printf '{invalid' > "$corrupt/toolkit.json"
  cout="$(MEGAPORT_CLI_BIN="$stub/megaport-cli" "$corrupt/lib/mp-cli.sh" --log-http ports list 2>&1)"; crc=$?
  if [ "$crc" -ne 0 ] && printf '%s' "$cout" | grep -q -- '--log-http'; then
    ok "corrupt toolkit.json still refuses (hardcoded fallback)"
  else
    bad "corrupt toolkit.json still refuses (hardcoded fallback)" "exit $crc: $cout"
  fi
  rm -rf "$corrupt" "$stub"
fi

# ---------------------------------------------------------------- redaction

group "redaction"

# mp_redact is what stands between a credential and the agent transcript, so
# each shape it claims to catch gets pinned here. The Bearer case is the one
# that regressed: redacting the scheme word instead of the token after it.
C="$ROOT/dist/claude-code/lib/common.sh"
if [ ! -f "$C" ]; then
  bad "common.sh built" "run ./build.sh first"
else
  redacts() {
    local label="$1" input="$2" leak="$3" out
    out="$(bash -c ". '$C'; mp_redact \"\$1\"" _ "$input")"
    if printf '%s' "$out" | grep -qF -- "$leak"; then
      bad "$label" "credential survived redaction: $out"
    else
      ok "$label"
    fi
  }

  redacts "bearer token after scheme word" \
          "Authorization: Bearer abc123def456xyz" "abc123def456xyz"
  redacts "basic auth value" \
          "Authorization: Basic dXNlcjpwYXNzd29yZA==" "dXNlcjpwYXNzd29yZA"
  redacts "bare authorization value" \
          "Authorization: sk_live_9a8b7c6d5e4f" "sk_live_9a8b7c6d5e4f"
  redacts "access_token pair" \
          "access_token=sk_live_9a8b7c6d5e4f3g2h1" "sk_live_9a8b7c6d5e4f3g2h1"
  redacts "MEGAPORT_* env assignment" \
          "MEGAPORT_SECRET_KEY=deadbeefcafe0123" "deadbeefcafe0123"
  redacts "JWT" \
          "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl" "c2lnbmF0dXJl"

  plain="$(bash -c ". '$C'; mp_redact 'fetched page ports/vxc for uid abc-123'")"
  if [ "$plain" = "fetched page ports/vxc for uid abc-123" ]; then
    ok "innocent text passes through untouched"
  else
    bad "innocent text passes through untouched" "got: $plain"
  fi
fi

# ---------------------------------------------------------------- build

group "build"

if "$ROOT/build.sh" --check >/dev/null 2>&1; then
  ok "dist/ matches build.sh output"
else
  bad "dist/ matches build.sh output" "run ./build.sh and commit the result"
fi

for hd in "$ROOT"/hosts/*/; do
  hid="$(jq -r '.id' "$hd/host.json")"
  pd="$(jq -r '.pluginDir' "$hd/host.json")"
  if [ -f "$ROOT/dist/$hid/$pd/plugin.json" ] && jq empty "$ROOT/dist/$hid/$pd/plugin.json" 2>/dev/null; then
    ok "manifest valid: $hid"
  else
    bad "manifest valid: $hid"
  fi
  mf="$(jq -r '.marketplace.file' "$hd/host.json")"
  if [ -f "$ROOT/$mf" ] && jq empty "$ROOT/$mf" 2>/dev/null; then
    ok "marketplace valid: $mf"
  else
    bad "marketplace valid: $mf"
  fi
done

# ---------------------------------------------------------------- network

if [ "$NETWORK" -eq 1 ]; then
  group "network"
  L="$ROOT/dist/claude-code/lib"

  # Capture first, match second. Piping straight into `grep -q` makes it exit on
  # the first match, SIGPIPEs the producer, and `pipefail` then reports a
  # successful match as a failed pipeline.
  matches() {
    local label="$1" pattern="$2"; shift 2
    local out
    out="$("$@" 2>/dev/null)"
    if printf '%s' "$out" | grep -qiE "$pattern"; then
      ok "$label"
    else
      bad "$label" "output did not match /$pattern/: $(printf '%s' "$out" | head -3)"
    fi
  }

  matches "docs index reachable"     'Getting Started'   "$L/mp-docs.sh" sections
  matches "docs index searchable"    'vxc'               "$L/mp-docs.sh" find VXC
  matches "docs page extraction"     'Creating a Private VXC' "$L/mp-docs.sh" page /connections/private-vxc/
  matches "terraform registry reachable" '^[0-9]+\.[0-9]+' "$L/mp-terraform.sh" version
  matches "provider resources listed" 'megaport_vxc'     "$L/mp-terraform.sh" list resources
  matches "provider doc content"     'megaport_vxc \(Resource\)' "$L/mp-terraform.sh" show megaport_vxc

  if "$L/mp-cli.sh" --install >/dev/null 2>&1; then
    matches "cli downloads, verifies and runs" \
      "$(jq -r .pins.megaport_cli_version "$CORE/toolkit.json")" "$L/mp-cli.sh" version
  else
    bad "cli downloads, verifies and runs" "install step failed"
  fi
  # The allowlist must actually block at runtime, not just in the static check.
  if out="$(bash -c ". '$L/common.sh'; mp_curl https://example.com/x" 2>&1)"; then
    bad "runtime allowlist blocks unknown host" "the call succeeded"
  else
    printf '%s' "$out" | grep -q 'not in the toolkit allowlist' \
      && ok "runtime allowlist blocks unknown host" \
      || bad "runtime allowlist blocks unknown host" "$out"
  fi

  # ...and it must block a host reached by redirect, which is the case checking
  # only the caller's URL misses entirely. api.github.com's tarball endpoint
  # 302s to codeload.github.com — a real GitHub host that is deliberately absent
  # from the allowlist, so this is a live redirect off the approved set with no
  # test-only host added to permit it. The CLI download above covers the other
  # half: a live 302 chain that must still be followed.
  tarball="https://api.github.com/repos/$(jq -r .pins.megaport_cli_repo "$CORE/toolkit.json")/tarball/v$(jq -r .pins.megaport_cli_version "$CORE/toolkit.json")"
  if out="$(bash -c ". '$L/common.sh'; mp_curl '$tarball' --output /dev/null" 2>&1)"; then
    bad "runtime allowlist blocks a redirect hop" "the call succeeded"
  else
    printf '%s' "$out" | grep -q "codeload.github.com' is not in the toolkit allowlist" \
      && ok "runtime allowlist blocks a redirect hop" \
      || bad "runtime allowlist blocks a redirect hop" "$out"
  fi
else
  printf '\n\033[33mskip\033[0m network tests (pass --network to run them)\n'
fi

# ----------------------------------------------------------------

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
