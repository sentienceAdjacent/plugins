#!/usr/bin/env bash
# Checks that this repo's Claude Code pin (the version that runs `claude plugin validate`) is the
# same in ci.yml and sync.yml, and the same as onenote-mcp's pin in its ci.yml and release.yml on
# main. Each repo pins it so a validator change can't break a green build unannounced; this check
# keeps the four pins in step (onenote-mcp backlog 25). onenote-mcp is public, so no token is needed.
#
# Needs: bash, curl, grep.
# Env overrides, for local runs: PIN_UPSTREAM_BASE (default the raw main branch of
# sentienceAdjacent/onenote-mcp; any URL curl reads, file:// included) and PIN_LOCAL_ROOT (default
# this repo's root).
set -euo pipefail
export LC_ALL=C

root=${PIN_LOCAL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
upstream=${PIN_UPSTREAM_BASE:-https://raw.githubusercontent.com/sentienceAdjacent/onenote-mcp/main}
package=@anthropic-ai/claude-code

fail() { echo "error: $*" >&2; exit 1; }

# An exact version: semver with an optional prerelease suffix, never a range or a dist-tag.
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

# pins_in NAME TEXT: the distinct versions TEXT installs, one per line. Comment lines are skipped;
# every other mention of the package must name an exact version.
pins_in() {
  local ref rest
  grep -vE '^[[:space:]]*#' <<< "$2" | grep -oE "${package}[^[:space:]\"']*" | while IFS= read -r ref; do
    rest=${ref#"$package"}
    [[ -z $rest || $rest == @* ]] || continue  # another package whose name starts the same
    [[ ${rest#@} =~ $version_pattern ]] || { echo "error: $1 installs '$ref', not an exact version." >&2; exit 1; }
    echo "${rest#@}"
  done | sort -u
  return "${PIPESTATUS[2]}"  # the loop's status; the greps find nothing in a file with no pin
}

declare -a names=() pins=()
add() {
  local name=$1 text=$2 found
  found=$(pins_in "$name" "$text") || exit 1
  [[ -n $found ]] || fail "$name installs no $package@<version>."
  [[ $found != *$'\n'* ]] || fail "$name pins more than one version: $(paste -sd' ' <<< "$found")."
  names+=("$name") pins+=("$found")
}

for f in ci.yml sync.yml; do
  path=$root/.github/workflows/$f
  [[ -f $path ]] || fail "$path is missing."
  add "plugins $f" "$(< "$path")"
done
for f in ci.yml release.yml; do
  url=$upstream/.github/workflows/$f
  text=$(curl -fsSL --retry 3 "$url") || fail "can't read onenote-mcp's $f from $url."
  add "onenote-mcp $f" "$text"
done

for i in "${!names[@]}"; do echo "${names[i]}: $package@${pins[i]}"; done
for i in "${!pins[@]}"; do
  [[ ${pins[i]} == "${pins[0]}" ]] \
    || fail "validator pins differ (${names[0]} has ${pins[0]}, ${names[i]} has ${pins[i]}). Bump them together."
done
echo "All validator pins are $package@${pins[0]}."
