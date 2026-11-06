#!/usr/bin/env bash
# Pins each plugin listed in .github/sources.json to its newest release.
#
# For each row {plugin, repo, asset, since}: find the newest non-draft release of `repo` whose tag is
# v<semver> (prereleases included) and not older than `since`, download its `asset` (with {version}
# filled in) and the asset's own .sha256, check the zip against it, and write the release url and
# sha256 into that plugin's archive entry in .claude-plugin/marketplace.json.
#
# The pin only moves forward by semver. An all-zero sha256 means "never released", so the first
# release always pins. The script only edits the catalog; the sync workflow validates and commits.
#
# Needs: bash, gh (GH_TOKEN set), jq, sha256sum.
# Env overrides, for local runs: SYNC_SOURCES, SYNC_MARKETPLACE, SYNC_SUMMARY (a file that gets one
# "<plugin> <tag>" line per new pin).
set -euo pipefail
export LC_ALL=C

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sources=${SYNC_SOURCES:-$root/.github/sources.json}
catalog=${SYNC_MARKETPLACE:-$root/.claude-plugin/marketplace.json}
summary=${SYNC_SUMMARY:-}
zero=0000000000000000000000000000000000000000000000000000000000000000

# Semver, optionally with a prerelease suffix; no build metadata. The same pattern as onenote-mcp's
# VERSION_PATTERN (release.yml), with \d written as [0-9] for bash.
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'

fail() { echo "error: $*" >&2; exit 1; }

# semver_gt A B: success when A > B by semver precedence (major.minor.patch[-prerelease]).
# Unchanged from onenote-mcp's release.yml (story 1.11, reviewed there).
semver_gt() {
  local a=$1 b=$2 ap= bp= i x y
  [[ $a == *-* ]] && ap=${a#*-}
  [[ $b == *-* ]] && bp=${b#*-}
  local -a ac bc ai bi
  IFS=. read -ra ac <<< "${a%%-*}"
  IFS=. read -ra bc <<< "${b%%-*}"
  for i in 0 1 2; do
    (( 10#${ac[i]} > 10#${bc[i]} )) && return 0
    (( 10#${ac[i]} < 10#${bc[i]} )) && return 1
  done
  [[ -z $ap ]] && { [[ -n $bp ]]; return; }  # a release outranks its prereleases
  [[ -z $bp ]] && return 1
  IFS=. read -ra ai <<< "$ap"
  IFS=. read -ra bi <<< "$bp"
  for (( i = 0; i < ${#ai[@]} && i < ${#bi[@]}; i++ )); do
    x=${ai[i]} y=${bi[i]}
    [[ $x == "$y" ]] && continue
    if [[ $x =~ ^[0-9]+$ && $y =~ ^[0-9]+$ ]]; then (( 10#$x > 10#$y )); return; fi
    [[ $x =~ ^[0-9]+$ ]] && return 1  # numeric identifiers rank below alphanumeric ones
    [[ $y =~ ^[0-9]+$ ]] && return 0
    [[ $x > $y ]]; return
  done
  (( ${#ai[@]} > ${#bi[@]} ))
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

rows=$(jq length "$sources")
for (( n = 0; n < rows; n++ )); do
  plugin=$(jq -r ".[$n].plugin" "$sources")
  repo=$(jq -r ".[$n].repo" "$sources")
  asset_template=$(jq -r ".[$n].asset" "$sources")
  since=$(jq -r ".[$n].since // empty" "$sources")
  [[ $asset_template == *'{version}'* ]] || fail "$sources row $n: asset '$asset_template' has no {version}."
  [[ -z $since || $since =~ $version_pattern ]] || fail "$sources row $n: since '$since' is not semver."

  [[ $(jq --arg p "$plugin" '[.plugins[] | select(.name == $p)] | length' "$catalog") == 1 ]] \
    || fail "$catalog has no single '$plugin' entry."
  current_url=$(jq -r --arg p "$plugin" '.plugins[] | select(.name == $p) | .source.url' "$catalog")
  current_sha=$(jq -r --arg p "$plugin" '.plugins[] | select(.name == $p) | .source.sha256' "$catalog")

  # The pinned version, unless the entry has never been released.
  current=
  if [[ $current_sha != "$zero" ]]; then
    prefix="https://github.com/$repo/releases/download/v"
    [[ $current_url == "$prefix"* ]] || fail "$plugin: can't read the pinned version from '$current_url'."
    rest=${current_url#"$prefix"}
    current=${rest%%/*}
    [[ $current =~ $version_pattern && $rest == "$current/${asset_template//\{version\}/$current}" ]] \
      || fail "$plugin: can't read the pinned version from '$current_url'."
  fi

  # The newest release by semver, prereleases included, ignoring tags that aren't v<semver>.
  tags=$(gh release list -R "$repo" --exclude-drafts --limit 1000 --json tagName --jq '.[].tagName')
  newest=
  while IFS= read -r tag; do
    version=${tag#v}
    [[ $tag == v* && $version =~ $version_pattern ]] || continue
    if [[ -n $since ]] && semver_gt "$since" "$version"; then continue; fi
    if [[ -z $newest ]] || semver_gt "$version" "$newest"; then newest=$version; fi
  done <<< "$tags"

  if [[ -z $newest ]]; then
    echo "$plugin: $repo has no release${since:+ at or after $since} yet; catalog left alone."
    continue
  fi
  if [[ -n $current ]]; then
    if [[ $newest == "$current" ]]; then
      echo "$plugin: already pins v$current."
      continue
    fi
    if ! semver_gt "$newest" "$current"; then
      echo "$plugin: pins v$current; the newest release, v$newest, is older, so the catalog is left alone."
      continue
    fi
  fi

  tag=v$newest
  file=${asset_template//\{version\}/$newest}
  names=$(gh release view "$tag" -R "$repo" --json assets --jq '.assets[].name')
  grep -qxF -- "$file" <<< "$names" && grep -qxF -- "$file.sha256" <<< "$names" \
    || fail "$plugin: release $repo $tag is missing $file or $file.sha256."

  dir=$work/$plugin
  mkdir -p "$dir"
  gh release download "$tag" -R "$repo" -p "$file" -p "$file.sha256" --dir "$dir"
  sha=$(sha256sum "$dir/$file" | cut -d' ' -f1)
  read -r recorded recorded_name _ < "$dir/$file.sha256" || true
  [[ $recorded == "$sha" && ${recorded_name#\*} == "$file" ]] \
    || fail "$plugin: $file from $repo $tag hashes to $sha, but its .sha256 says '$recorded  $recorded_name'."

  url="https://github.com/$repo/releases/download/$tag/$file"
  jq --indent 2 --arg p "$plugin" --arg url "$url" --arg sha "$sha" \
    '(.plugins[] | select(.name == $p) | .source) |= (.url = $url | .sha256 = $sha)' \
    "$catalog" > "$catalog.tmp"
  mv "$catalog.tmp" "$catalog"
  echo "$plugin: pinned $tag (sha256 $sha)${current:+, was v$current}."
  if [[ -n $summary ]]; then echo "$plugin $tag" >> "$summary"; fi
done
