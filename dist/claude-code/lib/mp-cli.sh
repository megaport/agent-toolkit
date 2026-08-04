#!/usr/bin/env bash
# Self-installing wrapper around the Megaport CLI.
#
# Resolves the correct OS/arch release asset from github.com/megaport/megaport-cli,
# verifies it against the published SHA256SUMS, caches it under a version-pinned
# path, and execs it with the caller's arguments.
#
# Usage:
#   mp-cli.sh [--] <megaport-cli args...>   run the CLI (installs on first use)
#   mp-cli.sh --install                     download + verify only
#   mp-cli.sh --path                        print the resolved binary path
#   mp-cli.sh --version                     print the pinned version
#   mp-cli.sh --system <args...>            use megaport-cli from PATH instead
#
# Environment:
#   MEGAPORT_CLI_VERSION   override the pinned version
#   MEGAPORT_CLI_BIN       use this binary verbatim, skip all download logic
#   MEGAPORT_TOOLKIT_CACHE override the cache root
#   MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS=1
#                          forward the flags listed in toolkit.json
#                          .safety.unsafeFlags instead of refusing them
#
# WHY THE VERSION IS PINNED, NOT RESOLVED:
#   megaport-cli publishes every release as a GitHub *pre-release*. As of writing
#   there are 59 releases and zero stable ones, so `GET /releases/latest` returns
#   HTTP 404. Any downloader written against "latest" breaks immediately. The
#   version lives in core/toolkit.json and is bumped deliberately by a maintainer.

set -euo pipefail
# shellcheck source=./common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CLI_NAME="megaport-cli"

cli_version() { printf '%s' "${MEGAPORT_CLI_VERSION:-$(mp_pin megaport_cli_version)}"; }
cli_repo()    { printf '%s' "$(mp_pin megaport_cli_repo)"; }

cli_dir() { printf '%s' "$(mp_cache_dir "cli/$(cli_version)")"; }
cli_bin() {
  local ext=""
  [ "$(mp_os)" = "windows" ] && ext=".exe"
  printf '%s/%s%s' "$(cli_dir)" "$CLI_NAME" "$ext"
}

# Verify one file against a SHA256SUMS manifest. Fails closed: a missing entry,
# a missing checksum tool, or a mismatch all abort the install.
cli_verify() {
  local file="$1" sums="$2" want got base
  base="$(basename "$file")"

  want="$(grep -E "[[:space:]][*]?${base}\$" "$sums" | awk '{print $1}' | head -1)"
  [ -n "$want" ] || mp_die "no checksum for $base in SHA256SUMS — refusing to install"

  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$file" | awk '{print $1}')"
  else
    mp_die "neither 'shasum' nor 'sha256sum' available — cannot verify the download, refusing to install"
  fi

  [ "$want" = "$got" ] || mp_die "checksum mismatch for $base (expected $want, got $got) — refusing to install"
  mp_log "verified $base against SHA256SUMS"
}

cli_install() {
  local version os arch asset tag base url tmp
  version="$(cli_version)"; os="$(mp_os)"; arch="$(mp_arch)"

  if [ -x "$(cli_bin)" ]; then
    printf '%s\n' "$(cli_bin)"
    return 0
  fi

  command -v unzip >/dev/null 2>&1 \
    || mp_die "'unzip' is required (every megaport-cli release asset is a .zip, on every platform)"

  asset="${CLI_NAME}_${version}_${os}_${arch}.zip"
  tag="v${version}"
  base="https://github.com/$(cli_repo)/releases/download/${tag}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mp-cli.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now, deliberately
  trap "rm -rf '$tmp'" EXIT

  mp_log "installing ${CLI_NAME} ${version} (${os}/${arch})"

  url="${base}/${asset}"
  mp_curl "$url" --output "$tmp/$asset" \
    || mp_die "could not download $asset. Check that ${tag} exists and publishes a ${os}/${arch} build: https://github.com/$(cli_repo)/releases"

  mp_curl "${base}/${CLI_NAME}_${version}_SHA256SUMS" --output "$tmp/SHA256SUMS"
  cli_verify "$tmp/$asset" "$tmp/SHA256SUMS"

  unzip -q -o "$tmp/$asset" -d "$tmp/x"

  # The archive also ships README.md, LICENSE and CHANGELOG.md, and the binary
  # carries the version in its name (megaport-cli_v1.0.0-beta.2). Match the
  # family, discard the documentation, then take the largest remaining file —
  # resilient to the exact binary name changing between releases.
  local found
  found="$(find "$tmp/x" -type f -name "${CLI_NAME}*" \
             ! -name '*.md' ! -name '*.txt' ! -name 'LICENSE*' \
           | while IFS= read -r p; do
               printf '%s\t%s\n' "$(wc -c < "$p" | tr -d ' ')" "$p"
             done | sort -rn | head -1 | cut -f2-)"
  [ -n "$found" ] || mp_die "no '$CLI_NAME' binary inside $asset (release layout changed?)"

  mkdir -p "$(cli_dir)"
  # Move into place atomically so a concurrent invocation never sees a partial
  # binary at the canonical path.
  mv "$found" "$(cli_bin).partial"
  chmod +x "$(cli_bin).partial"
  mv "$(cli_bin).partial" "$(cli_bin)"

  mp_log "installed to $(cli_bin)"
  printf '%s\n' "$(cli_bin)"
}

# --- unsafe flags -------------------------------------------------------------
# The wrapper forwards its arguments to the real CLI, so it is also a way to
# reach the CLI's most dangerous globals:
#
#   --base-url   points every API request, and the credentials that travel with
#                them, at a host of the caller's choosing — plain http included,
#                per the flag's own help text.
#   --token-url  does the same for the OAuth token exchange, i.e. for the API
#                key and secret themselves.
#   --log-http   writes raw HTTP, Authorization header and all, to stderr, where
#                it lands verbatim in the agent transcript. mp_redact only
#                covers what *this* toolkit writes; it cannot reach inside the
#                CLI's own output.
#
# This is convenience-layer defence, not the control. The PreToolUse hook
# (confirm-mutation.sh) escalates the same flags at the shell boundary, which is
# the check an agent cannot route around by calling the binary directly. Here we
# simply decline to be the shortcut.
#
# The list is policy and is read from toolkit.json so the hook and the wrapper
# cannot drift apart. If that read yields nothing — file missing, corrupt, key
# renamed — fall back to the three known flags rather than forwarding
# everything: a broken policy file must not quietly disable the refusal.
CLI_UNSAFE_FLAGS_FALLBACK="--base-url
--token-url
--log-http"

cli_unsafe_flags() {
  local flags=""
  if [ -f "$MP_TOOLKIT_JSON" ]; then
    flags="$(mp_json '.safety.unsafeFlags[]' "$MP_TOOLKIT_JSON" 2>/dev/null)" || flags=""
  fi
  case "$flags" in
    *-*) printf '%s' "$flags" ;;
    *)   printf '%s' "$CLI_UNSAFE_FLAGS_FALLBACK" ;;
  esac
}

cli_unsafe_reason() {
  case "$1" in
    --base-url)
      printf '%s' "it sends every API call, and the credentials with them, to a host of your choosing (plain HTTP included)" ;;
    --token-url)
      printf '%s' "it sends the OAuth token exchange, and the API key and secret with it, to a host of your choosing" ;;
    --log-http)
      printf '%s' "it writes raw HTTP including auth headers to stderr, where it is captured unredacted in the agent transcript" ;;
    *)
      printf '%s' "core/toolkit.json lists it under .safety.unsafeFlags" ;;
  esac
}

# Refuse before exec, on every path that forwards arguments. Matches both
# `--flag value` and `--flag=value`, which the CLI accepts interchangeably.
cli_check_unsafe_flags() {
  local unsafe arg name
  unsafe="$(cli_unsafe_flags)"

  for arg in "$@"; do
    case "$arg" in -*) ;; *) continue ;; esac
    name="${arg%%=*}"
    printf '%s\n' "$unsafe" | grep -Fxq -- "$name" || continue

    if [ "${MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS:-}" = "1" ]; then
      mp_warn "forwarding $name to $CLI_NAME because MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS=1 is set"
      continue
    fi

    mp_die "refusing to pass $name to $CLI_NAME: $(cli_unsafe_reason "$name"). If you have weighed that and still want it, run it yourself with MEGAPORT_TOOLKIT_ALLOW_UNSAFE_FLAGS=1 set."
  done
}

cli_resolve() {
  if [ -n "${MEGAPORT_CLI_BIN:-}" ]; then
    [ -x "$MEGAPORT_CLI_BIN" ] || mp_die "MEGAPORT_CLI_BIN=$MEGAPORT_CLI_BIN is not executable"
    printf '%s' "$MEGAPORT_CLI_BIN"
    return
  fi
  cli_install >/dev/null
  printf '%s' "$(cli_bin)"
}

# `mp_die` inside a command substitution only kills the subshell, so the exit
# status must be checked explicitly — otherwise a failed install falls through
# to `exec ""`.
cli_exec() {
  local bin
  cli_check_unsafe_flags "$@"
  bin="$(cli_resolve)" || exit 1
  [ -n "$bin" ] && [ -x "$bin" ] || mp_die "could not resolve a usable $CLI_NAME binary"
  exec "$bin" "$@"
}

main() {
  case "${1:-}" in
    --install) cli_install ;;
    --path)
      local bin; bin="$(cli_resolve)" || exit 1
      [ -n "$bin" ] || exit 1
      printf '%s\n' "$bin"
      ;;
    --version) cli_version; printf '\n' ;;
    --system)
      shift
      cli_check_unsafe_flags "$@"
      command -v "$CLI_NAME" >/dev/null 2>&1 || mp_die "$CLI_NAME not found on PATH"
      exec "$CLI_NAME" "$@"
      ;;
    --) shift; cli_exec "$@" ;;
    *)  cli_exec "$@" ;;
  esac
}

main "$@"