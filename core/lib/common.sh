#!/usr/bin/env bash
# Shared runtime for the Megaport Agent Toolkit.
#
# Sourced by every other script in this directory. Targets bash 3.2 (the version
# macOS still ships) — no associative arrays, no `mapfile`, no `${x^^}`.
#
# Dependencies: curl, plus either jq or python3. Everything else is coreutils.

set -euo pipefail

# --- self-location -----------------------------------------------------------
# Scripts must work when invoked by absolute path, via a host's plugin-root
# variable, or through a symlink. Never rely on $PWD or on a host-injected var.
MP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MP_ROOT="$(cd "$MP_LIB_DIR/.." && pwd)"
MP_TOOLKIT_JSON="$MP_ROOT/toolkit.json"
export MP_LIB_DIR MP_ROOT MP_TOOLKIT_JSON

MP_CACHE="${MEGAPORT_TOOLKIT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/megaport-agent-toolkit}"
export MP_CACHE

# --- logging -----------------------------------------------------------------
# All diagnostics go to stderr so stdout stays clean for the agent to consume.

mp_log()  { printf '%s\n' "$(mp_redact "$*")" >&2; }
mp_warn() { printf 'warning: %s\n' "$(mp_redact "$*")" >&2; }
mp_die()  { printf 'error: %s\n' "$(mp_redact "$*")" >&2; exit 1; }

# Best-effort: strip known credential shapes before they can reach a log, a
# transcript or the model's context. Applied at write time, per the toolkit's
# stated security posture. Pattern-based, so it catches the shapes below and
# nothing it has never seen — do not describe it as a guarantee. The stronger
# property is that these scripts never read or handle credentials at all; only
# the CLI does.
mp_redact() {
  # The Authorization value may be `<token>` or `<scheme> <token>` — the
  # optional word group swallows the scheme so the token itself is what gets
  # redacted, not just the word "Bearer" in front of it.
  printf '%s' "$*" | sed -E \
    -e 's/(Authorization:[[:space:]]*)([A-Za-z]+[[:space:]]+)?[^[:space:]]+/\1[REDACTED]/gI' \
    -e 's/((access|refresh|api|secret|bearer)[_-]?(token|key)[=:"[:space:]]+)[A-Za-z0-9._~+\/-]{8,}/\1[REDACTED]/gI' \
    -e 's/(MEGAPORT_[A-Z_]*(KEY|SECRET|TOKEN)=)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(eyJ[A-Za-z0-9_-]{10,})\.[A-Za-z0-9._-]+/[REDACTED-JWT]/g'
}

# --- JSON --------------------------------------------------------------------
# Prefer jq; fall back to python3. Fail loudly rather than silently degrading to
# a regex "parser", which is how these scripts usually start lying.

MP_JSON_ENGINE=""
mp_json_engine() {
  if [ -n "$MP_JSON_ENGINE" ]; then printf '%s' "$MP_JSON_ENGINE"; return; fi
  if command -v jq >/dev/null 2>&1; then
    MP_JSON_ENGINE=jq
  elif command -v python3 >/dev/null 2>&1; then
    MP_JSON_ENGINE=python3
  else
    mp_die "needs either 'jq' or 'python3' on PATH to parse JSON. Install one: 'brew install jq' or 'apt-get install jq'."
  fi
  printf '%s' "$MP_JSON_ENGINE"
}

# mp_json FILTER [FILE]
# FILTER is a jq path expression, e.g. '.pins.megaport_cli_version' or
# '.data[].attributes.title'. The python3 fallback supports the dotted-path and
# simple-iteration subset actually used by this toolkit, and errors on anything
# richer rather than guessing.
mp_json() {
  local filter="$1"; shift
  local src="${1:--}"
  case "$(mp_json_engine)" in
    jq)
      jq -r "$filter" "$src"
      ;;
    python3)
      MP_FILTER="$filter" python3 - "$src" <<'PY'
import json, os, sys
filt = os.environ["MP_FILTER"].strip()
src = sys.argv[1]
data = json.load(sys.stdin if src == "-" else open(src))

def emit(v):
    if v is None:
        print("null")
    elif isinstance(v, (dict, list)):
        print(json.dumps(v))
    elif isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)

# Supported subset: .a.b.c  |  .a[].b  |  .a[]  |  .
if filt in (".", ""):
    emit(data); sys.exit(0)

if not filt.startswith("."):
    sys.stderr.write("error: unsupported jq filter in python3 fallback: %s\n" % filt)
    sys.exit(2)

cur = [data]
for part in filt[1:].split("."):
    if not part:
        continue
    explode = part.endswith("[]")
    key = part[:-2] if explode else part
    nxt = []
    for node in cur:
        val = node.get(key) if isinstance(node, dict) else None
        if val is None:
            continue
        if explode:
            nxt.extend(val if isinstance(val, list) else val.values() if isinstance(val, dict) else [val])
        else:
            nxt.append(val)
    cur = nxt

for v in cur:
    emit(v)
PY
      ;;
  esac
}

# mp_pin KEY -> value from toolkit.json .pins
mp_pin() {
  [ -f "$MP_TOOLKIT_JSON" ] || mp_die "toolkit.json not found at $MP_TOOLKIT_JSON (broken install?)"
  mp_json ".pins.$1" "$MP_TOOLKIT_JSON"
}

# --- network -----------------------------------------------------------------
# Every request is checked against the allowlist in toolkit.json at call time —
# every *hop* of it, not just the URL the caller passed. tests/run.sh performs
# the same check statically; this is defence in depth so a runtime-constructed
# URL cannot escape the policy either.

mp_host_allowed() {
  local host="$1" allowed
  [ -f "$MP_TOOLKIT_JSON" ] || return 1
  allowed="$(mp_json '.allowedHosts.hosts[]' "$MP_TOOLKIT_JSON")"
  printf '%s\n' "$allowed" | grep -Fxq "$host"
}

# mp_url_allowed URL [CONTEXT] -> dies unless the URL is HTTPS and its host is
# on the allowlist. Split out of mp_curl because the same check has to be
# applied to every redirect target, where CONTEXT records where it came from.
mp_url_allowed() {
  local url="$1" why="${2:-}" host

  case "$url" in
    https://*) ;;
    *) mp_die "refusing non-HTTPS request to $url${why:+ ($why)}" ;;
  esac

  host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#[/?].*$##; s#^[^@]*@##; s#:[0-9]+$##')"

  mp_host_allowed "$host" \
    || mp_die "host '$host' is not in the toolkit allowlist${why:+ ($why)}. If this is intentional, add it to core/toolkit.json -> allowedHosts.hosts and explain why in the PR."
}

# mp_curl URL [extra curl args...] -> body on stdout
#
# GUARANTEE: every host that participates in the request is on the allowlist.
#
# Validating only the caller's URL and then handing curl `--location` does not
# give that: any allowlisted endpoint could 302 the request to anywhere it
# liked. That is not theoretical here — mp-cli.sh pulls a binary *and* the
# SHA256SUMS it is checked against through this function, so one redirect that
# both requests follow would have the attacker's file verified against the
# attacker's digest, and the checksum step would prove nothing.
#
# Redirects cannot simply be switched off: GitHub serves every release asset as
# a 302 to *.githubusercontent.com. So the chain is resolved first with
# metadata-only requests, each hop validated before it is adopted, and only the
# fully-validated final URL is fetched.
#
# Fail-closed in both directions:
#   - a chain longer than MP_MAX_REDIRECTS aborts rather than being followed;
#   - if HEAD itself fails (some CDNs reject it) we fetch the current, already
#     validated URL *without* --location, so an unfollowed redirect yields an
#     empty or 3xx body and the caller's own checks (checksum, unzip, content
#     sniff) fail loudly instead of silently taking bytes from an unvetted host.
mp_curl() {
  local url="$1"; shift
  local ua why="" hop=0 meta code next
  ua="megaport-agent-toolkit/$(mp_json '.version' "$MP_TOOLKIT_JSON" 2>/dev/null || echo dev)"

  while :; do
    mp_url_allowed "$url" "$why"
    hop=$((hop + 1))
    [ "$hop" -le "${MP_MAX_REDIRECTS:-5}" ] \
      || mp_die "redirect chain exceeded ${MP_MAX_REDIRECTS:-5} hops at $url — refusing to keep following it"

    # -I transfers no body, so nothing from an unvalidated host is ever read.
    # No --fail: a 4xx/5xx here is not a redirect, and the real GET below is
    # where the status matters. curl resolves %{redirect_url} to an absolute
    # URL even when the Location header is relative.
    meta="$(curl --silent --show-error --head --output /dev/null \
                 --max-time "${MP_HTTP_TIMEOUT:-45}" \
                 --user-agent "$ua" \
                 --write-out '%{http_code} %{redirect_url}' "$url" 2>/dev/null)" || break

    code="${meta%% *}"
    next=""
    case "$meta" in *" "*) next="${meta#* }" ;; esac
    case "$code" in
      3[0-9][0-9]) [ -n "$next" ] || break ;;
      *) break ;;
    esac

    why="redirected from $url"
    url="$next"
  done

  curl --fail --silent --show-error \
       --max-time "${MP_HTTP_TIMEOUT:-45}" \
       --retry 2 --retry-delay 1 \
       --user-agent "$ua" \
       "$@" "$url"
}

# --- cache -------------------------------------------------------------------

mp_cache_dir() {
  local sub="${1:-}"
  local d="$MP_CACHE${sub:+/$sub}"
  mkdir -p "$d"
  printf '%s' "$d"
}

# mp_cache_fresh FILE MAX_AGE_SECONDS -> 0 if the file exists and is new enough
mp_cache_fresh() {
  local f="$1" max="$2" mtime now
  [ -f "$f" ] || return 1
  # stat differs between BSD (macOS) and GNU (Linux).
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [ "$((now - mtime))" -lt "$max" ]
}

# --- platform ----------------------------------------------------------------
# Normalised to the naming used by megaport-cli's release assets:
#   megaport-cli_<version>_<os>_<arch>.zip
# os:   darwin | linux | windows | freebsd
# arch: amd64  | arm64 | arm | 386

mp_os() {
  local u; u="$(uname -s)"
  case "$u" in
    Darwin)  printf 'darwin' ;;
    Linux)   printf 'linux' ;;
    FreeBSD) printf 'freebsd' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) mp_die "unsupported operating system: $u" ;;
  esac
}

mp_arch() {
  local u; u="$(uname -m)"
  case "$u" in
    x86_64|amd64)  printf 'amd64' ;;
    arm64|aarch64) printf 'arm64' ;;
    armv7l|armv6l) printf 'arm' ;;
    i386|i686)     printf '386' ;;
    *) mp_die "unsupported architecture: $u" ;;
  esac
}
