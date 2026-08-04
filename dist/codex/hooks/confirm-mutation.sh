#!/usr/bin/env bash
# PreToolUse guard: escalate infrastructure-mutating commands to a human.
#
#   confirm-mutation.sh --dialect pretooluse   Claude Code and Codex
#   confirm-mutation.sh --dialect cursor       Cursor
#
# WHY A HOOK AND NOT A WRAPPER SCRIPT
#   A "shim" on PATH is not a control. The agent can invoke `megaport-cli`
#   directly through its shell tool and never touch the shim. Only a host
#   PreToolUse hook sits in the path of every shell invocation, which is why the
#   gate lives here.
#
# WHAT THIS DOES AND DOES NOT GUARANTEE
#   Does:      any guarded command whose verb is not on the read-only allowlist
#              is escalated to a human prompt before it runs. Fail-closed — an
#              unrecognised verb escalates, an unreadable payload escalates, a
#              missing or corrupt config escalates, and a guarded binary whose
#              invocation cannot be resolved from the tokens escalates.
#   Does not:  prevent a determined agent from reaching the API by other means
#              (raw curl, a Python script, an MCP tool), or catch a shell
#              command obfuscated so the guarded name never appears in the text
#              it inspects (eval, strings built from variables). It classifies
#              commands as text. Do not describe it as a guarantee that nothing
#              changes without approval — that claim will not survive a
#              security review.
#
# WHY UNPARSEABLE INPUT ESCALATES
#   The hook is registered only against the shell tools (matcher ^(Bash|Shell)$,
#   or beforeShellExecution), so every payload it is handed is a shell command
#   that is about to run. "I could not read the payload" therefore means "I could
#   not inspect the command", and allowing on that is the same as switching the
#   control off exactly when it is broken. Empty stdin, malformed JSON, a moved
#   command field and a host with neither jq nor python3 all escalate.
#
# DIALECTS
#   pretooluse : stdin  {"hook_event_name":"PreToolUse","tool_name":…,"tool_input":{"command":…}}
#                stdout {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#                        "permissionDecision":"allow|ask|deny","permissionDecisionReason":…}}
#                Claude Code and Codex are wire-identical here.
#   cursor     : stdin  {"hook_event_name":"beforeShellExecution","command":…,"cwd":…}
#                stdout {"permission":"allow|deny","user_message":…,"agent_message":…}
#                Denial additionally requires exit code 2.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HOOK_DIR/.." && pwd)"
TOOLKIT_JSON="$ROOT/toolkit.json"

DIALECT="pretooluse"
while [ $# -gt 0 ]; do
  case "$1" in
    --dialect) DIALECT="${2:-pretooluse}"; shift 2 ;;
    *) shift ;;
  esac
done

# --- responses ---------------------------------------------------------------

allow() {
  case "$DIALECT" in
    cursor) printf '{"permission":"allow"}\n' ;;
    *)      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n' ;;
  esac
  exit 0
}

# Escalate to the human. On Claude Code and Codex this is `ask`, which surfaces
# the host's own approval prompt. Cursor has no `ask`, so the strongest
# available action is a deny carrying an explanation.
#
# The cursor agent_message deliberately offers the agent no way to retry. There
# is no bypass variable and no bypass flag: an agent-settable self-approval
# switch would just become the thing the agent reaches for, which is the exact
# control this hook exists to provide.
escalate() {
  local reason="$1"
  case "$DIALECT" in
    cursor)
      json_out \
        '{"permission":"deny","user_message":%s,"agent_message":%s}' \
        "$(jstr "Megaport Agent Toolkit blocked a command that can change live infrastructure: $reason")" \
        "$(jstr "This command was blocked because it can modify live Megaport infrastructure ($reason). Show the user the exact command verbatim, explain what it would change, and ask them to confirm. If they approve, ask them to run it themselves in their own terminal — this hook cannot be satisfied on your behalf and there is no flag or environment variable that bypasses it.")"
      exit 2
      ;;
    *)
      json_out \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}' \
        "$(jstr "This command can change live Megaport infrastructure: $reason")"
      exit 0
      ;;
  esac
}

json_out() { local fmt="$1"; shift; printf "$fmt" "$@"; printf '\n'; }

# Minimal JSON string encoder — enough for the messages above.
jstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    | awk 'BEGIN{printf "\""} {printf "%s", (NR>1 ? "\\n" : "") $0} END{printf "\""}'
}

# --- input -------------------------------------------------------------------

payload="$(cat)"

have_jq()      { command -v jq >/dev/null 2>&1; }
have_python()  { command -v python3 >/dev/null 2>&1; }

# Every escalation below is reachable without a JSON parser: jstr and json_out
# are sed/awk/printf only, so the hook can still explain itself on a host that
# has neither tool.
if ! have_jq && ! have_python; then
  escalate "no JSON tool available to inspect the command (this hook needs jq or python3)"
fi

[ -n "$payload" ] || escalate "empty hook payload, so the command could not be inspected"

payload_is_json() {
  if have_jq; then
    printf '%s' "$payload" | jq -e . >/dev/null 2>&1
  else
    printf '%s' "$payload" | python3 -c 'import sys, json; json.load(sys.stdin)' >/dev/null 2>&1
  fi
}

payload_is_json || escalate "unparseable hook payload, so the command could not be inspected"

extract() {
  local path="$1"
  if have_jq; then
    printf '%s' "$payload" | jq -r "$path // empty" 2>/dev/null
  else
    printf '%s' "$payload" | MP_PATH="$path" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur = d
for k in os.environ["MP_PATH"].lstrip(".").split("."):
    if not k:
        continue
    if not isinstance(cur, dict):
        sys.exit(0)
    cur = cur.get(k)
    if cur is None:
        sys.exit(0)
print(cur if isinstance(cur, str) else json.dumps(cur))' 2>/dev/null
  fi
}

case "$DIALECT" in
  cursor) command_line="$(extract '.command')" ;;
  *)      command_line="$(extract '.tool_input.command')" ;;
esac

# Valid JSON, but not the shape this dialect promised — the host moved the
# command field, or sent an event we do not understand. Either way there is a
# shell command behind it that nobody has classified.
[ -n "${command_line:-}" ] || escalate "hook payload carries no command, so nothing could be classified"

# --- config ------------------------------------------------------------------
# Fail closed: if the policy cannot be read, escalate rather than wave things
# through. A broken install must not silently disable the control.

# The classification of last resort, used when there is no usable policy: anything
# naming a guarded tool goes to the human, everything else is none of our business.
# Both "no policy" paths share it so they cannot drift apart — the file being
# absent and the file being corrupt are the same situation for the caller.
policy_unavailable() {
  case "$(printf '%s' "$command_line" | tr '[:upper:]' '[:lower:]')" in
    *megaport-cli*|*mp-cli.sh*|*terraform*|*tofu*) escalate "$1" ;;
    *) allow ;;
  esac
}

[ -f "$TOOLKIT_JSON" ] \
  || policy_unavailable "toolkit policy file is missing, so the command could not be classified"

cfg() {
  if have_jq; then
    jq -r "$1" "$TOOLKIT_JSON" 2>/dev/null
  else
    MP_Q="$1" python3 -c '
import sys, json, os
d = json.load(open(sys.argv[1]))
q = os.environ["MP_Q"]
cur = d
for k in q.lstrip(".").replace("[]", "").split("."):
    if k:
        cur = cur.get(k, [])
for v in (cur if isinstance(cur, list) else [cur]):
    print(v)' "$TOOLKIT_JSON" 2>/dev/null
  fi
}

read_verbs="$(cfg '.safety.readOnlyVerbs[]')"
read_prefixes="$(cfg '.safety.readOnlyVerbPrefixes[]')"
value_flags="$(cfg '.safety.valueFlags[]')"
help_flags="$(cfg '.safety.helpFlags[]')"
unsafe_flags="$(cfg '.safety.unsafeFlags[]')"
guarded="$(cfg '.safety.guardedCommands[]')"
always="$(cfg '.safety.alwaysEscalate[]')"
verb_window="$(cfg '.safety.verbWindow')"
case "$verb_window" in ''|*[!0-9]*) verb_window=2 ;; esac

# A present-but-corrupt toolkit.json returns empty for every query, which would
# leave the guarded list empty, skip the whole classification loop and allow
# everything. Without this check the file-missing branch above is the only
# fail-closed path, and it is the less likely failure of the two.
if [ -z "$read_verbs" ] || [ -z "$guarded" ]; then
  policy_unavailable "toolkit policy could not be read, so the command could not be classified"
fi

# --- classification ----------------------------------------------------------

# Whole-string form, used only by the alwaysEscalate substring pass below.
# Folding newlines into spaces and case to lower here can only *create* a match
# ("terraform" and "apply" on separate lines reading as "terraform apply"),
# which escalates a command that would not have mutated anything — noisy, but
# the safe direction.
normalised="$(printf '%s' "$command_line" | tr '\n' ' ' | tr -s '[:space:]' ' ' | tr '[:upper:]' '[:lower:]')"

# 1. Unconditional escalations, checked first.
if [ -n "$always" ]; then
  while IFS= read -r phrase; do
    [ -n "$phrase" ] || continue
    case "$normalised" in
      *"$phrase"*) escalate "'$phrase' modifies real infrastructure" ;;
    esac
  done <<EOF
$always
EOF
fi

# 2. Guarded binaries: allowlist their read-only verbs, escalate everything else.
#
#    megaport-cli's grammar is `megaport-cli [global flags] <group> <verb> [args]`
#    (`ports list`, `vxc buy`, `mcr get <uid>`), so the operative verb is within
#    the first two non-flag tokens. Looking only at the first would misread
#    `ports` as the verb; looking at all of them would let a stray `list`
#    argument launder a `buy`.

is_read_verb() {
  local v="$1" p
  printf '%s\n' "$read_verbs" | grep -Fxq -- "$v" && return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # A prefix matches the bare verb or a hyphenated extension of it:
    # "list" covers list, list-tags, list-prefix-filter-lists.
    case "$v" in "$p"|"$p"-*) return 0 ;; esac
  done <<EOF
$read_prefixes
EOF
  return 1
}

vflags_line="$(printf '%s' "$value_flags"  | tr '\n' ' ')"
hflags_line="$(printf '%s' "$help_flags"   | tr '\n' ' ')"
uflags_line="$(printf '%s' "$unsafe_flags" | tr '\n' ' ')"
bins_line="$(printf '%s' "$guarded"        | tr '\n' ' ')"

# The two characters awk strips off the ends of a token. Passed in rather than
# written inline so the awk program itself stays single-quotable.
QUOTES="\"'"

# Compound commands are split so the safe half cannot mask the dangerous half:
# `megaport-cli ports list && megaport-cli ports delete x` still escalates.
# A newline is a command separator exactly like `;` — without it, a two-line
# script collapses into one segment and its read-only line vouches for its
# mutating one.
segments="$(printf '%s\n' "$command_line" | awk '{gsub(/&&|\|\||;|\|/, "\n"); print}')" \
  || escalate "this command could not be split into inspectable segments"

# Per-segment tokeniser. Emits, in order:
#
#   unsafe <flag>          a credential/endpoint-rerouting global flag is present
#   occ <bin> help|verbs   one invocation of a guarded binary
#   verb <token>           a verb-window token belonging to the preceding `occ`
#   opaque <bin>           the name is in the segment but no token invokes it
#
# Each *occurrence* is reported separately: pooling every verb in the segment
# lets `megaport-cli ports list megaport-cli ports delete x` clear the delete on
# the strength of the list.
#
# Fed by here-doc rather than a pipe so the exit status belongs to awk alone: a
# tokeniser that fell over must be distinguishable from one that found nothing.
scan_segment() {
  awk \
    -v bins=" $bins_line " -v vflags=" $vflags_line " -v hflags=" $hflags_line " \
    -v uflags=" $uflags_line " -v win="$verb_window" -v q="$QUOTES" '
    # A quoted invocation (bash -c, sh -c, ssh) tokenises the binary with the
    # opening quote still attached, and that matches no name until it comes off.
    function unq(s) {
      while (length(s) > 0 && index(q, substr(s, 1, 1)) > 0) s = substr(s, 2)
      while (length(s) > 0 && index(q, substr(s, length(s), 1)) > 0) s = substr(s, 1, length(s) - 1)
      return s
    }
    # True when name appears in s delimited by non-word characters, i.e. as
    # something that could be a command rather than part of a longer word.
    # `$(megaport-cli` qualifies; `terraform.tfvars` and `run-terraform.sh` do not.
    function mentions(s, name,   p, before, after) {
      p = index(s, name)
      if (p == 0) return 0
      before = (p == 1 ? "" : substr(s, p - 1, 1))
      after  = substr(s, p + length(name), 1)
      if (before != "" && before ~ /[A-Za-z0-9._-]/) return 0
      if (after  != "" && after  ~ /[A-Za-z0-9._-]/) return 0
      return 1
    }
    function base_of(t,   b) { b = unq(t); sub(/^.*\//, "", b); return b }
    {
      nb = split(bins, b, " ")
      n  = split($0, tok, " ")

      # Everything from the first `#` token onwards is a shell comment and never
      # executes, so it must not be able to vouch for what precedes it either:
      # `megaport-cli ports delete abc # --help` really does delete.
      end = n
      for (i = 1; i <= n; i++) if (substr(tok[i], 1, 1) == "#") { end = i - 1; break }

      # Flags that repoint the API or token endpoint, or dump auth headers, are
      # disqualifying on their own — the verb is irrelevant if the credentials
      # are going somewhere else.
      for (i = 1; i <= end; i++) {
        t = unq(tok[i])
        eq = index(t, "=")
        if (eq > 0) t = substr(t, 1, eq - 1)
        if (index(uflags, " " t " ") > 0) { print "unsafe " t; exit }
      }

      # Binary names match case-insensitively: the filesystems macOS and
      # Windows ship are case-insensitive, so `MEGAPORT-CLI` executes the real
      # binary and must be classified like it.
      for (i = 1; i <= end; i++) {
        base = tolower(base_of(tok[i]))
        for (k = 1; k <= nb; k++) {
          if (base != b[k] && base != b[k] ".exe") continue
          seen[b[k]] = 1
          help = 0; cnt = 0; buf = ""; noflags = 0
          # Verbs stop at the window; the help scan does not. `vxc buy --help`
          # fills the window before reaching the flag, and help output that the
          # window never sees is still help output.
          for (j = i + 1; j <= end; j++) {
            t = unq(tok[j])
            # `--` ends flag parsing: everything after it is an argument, not a
            # flag, so a help flag beyond it cannot summon help —
            # `ports delete x -- --help` really does run the delete.
            if (t == "--") { noflags = 1; continue }
            if (!noflags && t ~ /^-/) {
              if (index(hflags, " " t " ") > 0) { help = 1; break }
              # `--output json` consumes its value; `--output=json` does not.
              # A help flag consumed as a value is a value, not a request for help.
              if (t !~ /=/ && index(vflags, " " t " ") > 0) j++
              continue
            }
            if (cnt < win) { buf = buf "verb " t "\n"; cnt++ }
          }
          if (help) { print "occ " b[k] " help" } else { printf "occ %s verbs\n%s", b[k], buf }
        }
      }

      # A guarded name that is in the segment but never resolved to a token we
      # can read — `echo "$(megaport-cli ports delete x)"` hides it inside
      # `$(megaport-cli`. We cannot see the verb, so we cannot clear it.
      for (k = 1; k <= nb; k++) {
        if (b[k] in seen) continue
        for (i = 1; i <= end; i++) {
          if (mentions(tolower(base_of(tok[i])), b[k])) { print "opaque " b[k]; break }
        }
      }
    }' <<EOF
$1
EOF
}

# State for the occurrence currently being read out of scan_segment.
occ_open=0; occ_ok=0; occ_verbs=0; occ_bin=""; occ_first=""

close_occurrence() {
  [ "$occ_open" -eq 1 ] || return 0
  occ_open=0
  # A bare invocation (`megaport-cli` alone, `mp-cli.sh --version`) prints help
  # or a version string; there is no verb to classify.
  [ "$occ_verbs" -eq 0 ] && return 0
  [ "$occ_ok" -eq 1 ] && return 0
  escalate "'$occ_bin $occ_first' is not a known read-only operation"
}

while IFS= read -r segment; do
  [ -n "$segment" ] || continue

  # Cheap pre-filter: most segments name no guarded tool at all. Folded to
  # lower case so `MEGAPORT-CLI` — which a case-insensitive filesystem happily
  # executes — cannot skip the scan.
  seg_guarded=0
  seg_folded="$(printf '%s' "$segment" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r bin; do
    [ -n "$bin" ] || continue
    case "$seg_folded" in *"$bin"*) seg_guarded=1; break ;; esac
  done <<EOF
$guarded
EOF
  [ "$seg_guarded" -eq 1 ] || continue

  # An awk that refused to run is not evidence of a safe command.
  records="$(scan_segment "$segment")" \
    || escalate "this command could not be tokenised for inspection"
  [ -n "$records" ] || continue

  occ_open=0; occ_ok=0; occ_verbs=0; occ_bin=""; occ_first=""
  while IFS= read -r rec; do
    case "$rec" in
      "unsafe "*)
        escalate "'${rec#unsafe }' points credentials or API traffic away from the pinned Megaport endpoints" ;;
      "opaque "*)
        escalate "could not determine how '${rec#opaque }' is invoked here, so it could not be classified" ;;
      "occ "*)
        close_occurrence
        rest="${rec#occ }"
        occ_open=1; occ_verbs=0; occ_first=""
        occ_bin="${rest% *}"
        case "$rest" in *" help") occ_ok=1 ;; *) occ_ok=0 ;; esac
        ;;
      "verb "*)
        v="${rec#verb }"
        occ_verbs=$((occ_verbs + 1))
        [ -n "$occ_first" ] || occ_first="$v"
        is_read_verb "$v" && occ_ok=1
        ;;
    esac
  done <<EOF
$records
EOF
  close_occurrence
done <<EOF
$segments
EOF

allow