# sentienceAdjacent plugins

A Claude Code plugin marketplace for sentienceAdjacent's plugins and skills.

## Install

```text
/plugin marketplace add sentienceAdjacent/plugins
/plugin install onenote@sentienceadjacent
```

Update with `/plugin marketplace update sentienceadjacent`, and remove a plugin with `/plugin uninstall onenote@sentienceadjacent`.

## Plugins

| Plugin | What it does | Source |
|---|---|---|
| `onenote` | Read and manage OneNote desktop notebooks on Windows through OneNote's COM API. | [sentienceAdjacent/onenote-mcp](https://github.com/sentienceAdjacent/onenote-mcp) |

## How pins are updated

Each plugin built from releases is listed in `.github/sources.json`. After each release, run the `sync` workflow with `gh workflow run sync -R sentienceAdjacent/plugins`. Its daily run is only a backstop: GitHub pauses scheduled workflows in a public repo after 60 days without activity (re-enable it from the Actions tab). For each plugin it finds the newest release by semver (prereleases included), downloads the release zip and its `.sha256`, checks one against the other, and commits the new `url` and `sha256` to `.claude-plugin/marketplace.json`. A pin only moves forward, and an all-zero `sha256` means the plugin hasn't been released yet. The workflow uses only this repo's own `GITHUB_TOKEN`; no other repo can write here.

## Licences

The catalog and scripts in this repo are under the [MIT licence](LICENSE). Each plugin keeps its own licence, given in its own repo: installing a plugin from here doesn't change its terms.
