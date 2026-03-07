# zsh-fuzzytab

![zsh-fuzzytab demo](assets/demo.gif)

Type `gst`, press `Tab`, and the command expands to `git status`.

`zsh-fuzzytab` turns `Tab` into fuzzy history recall for zsh.

Type part of a command, press `Tab`, and the shell expands to the best matching entry from your history. If there is no match, or `fzf` is not available, it falls back to normal completion.

## Why this is useful

- Faster than reaching for `Ctrl-R`
- Works with intent fragments, not just prefixes
- Keeps normal completion as the fallback path

This packages the idea from [Fuzzy Tab](https://ody.yachts/presents/fuzzy-tab) as a reusable zsh plugin.

## Requirements

- `zsh` 5.8+
- [`fzf`](https://github.com/junegunn/fzf)

## Install

Most zsh plugins are published as a GitHub repo and consumed directly by plugin managers. There is usually no separate registry publish step.

Assuming the repo slug is `lydakis/zsh-fuzzytab`:

### Antigen

```zsh
antigen bundle lydakis/zsh-fuzzytab
```

### Antibody

```zsh
antibody bundle lydakis/zsh-fuzzytab
```

### Zinit

```zsh
zinit light lydakis/zsh-fuzzytab
```

### zplug

```zsh
zplug "lydakis/zsh-fuzzytab"
```

### Oh My Zsh custom plugin

```zsh
git clone https://github.com/lydakis/zsh-fuzzytab \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-fuzzytab
```

Then add `zsh-fuzzytab` to the `plugins=(...)` list in `.zshrc`.

### Manual source

```zsh
source /path/to/zsh-fuzzytab/fuzzy-tab.plugin.zsh
```

The repo also ships `zsh-fuzzytab.plugin.zsh` for plugin managers that prefer a repo-name entrypoint.

## Configuration

The plugin auto-binds `Tab` by default in interactive shells.

```zsh
# Optional: choose a different key
FUZZY_TAB_BINDKEY='^G'

# Optional: skip the auto-bind and wire it up yourself later
FUZZY_TAB_DISABLE_AUTO_BIND=1

# Optional: change the fallback completion widget
FUZZY_TAB_COMPLETION_WIDGET=expand-or-complete

# Optional: pass extra flags to fzf
typeset -ga FUZZY_TAB_FZF_OPTS=(--tiebreak=index)

source /path/to/zsh-fuzzytab/fuzzy-tab.plugin.zsh

# Optional manual bind when auto-bind is disabled
fuzzy_tab_bind '^I'
```

## Behavior

- The current left-side buffer (`LBUFFER`) is used as the fuzzy query.
- History is read newest-first via `fc -rl 1`.
- Duplicate commands are removed so repeated commands do not crowd results.
- The first fuzzy hit is inserted into the command line.
- If the buffer is empty, there is no match, or `fzf` is unavailable, normal completion runs instead.

## Development

Run the test suite:

```zsh
zsh tests/run.zsh
```

README demo assets:

- `assets/demo.cast` is the source recording captured with `asciinema`
- `assets/demo.gif` is the rendered animation generated from that cast

## Publishing checklist

1. Push this repo to GitHub.
2. Create a `v1.0.0` tag and GitHub release.
3. Add the repo to your preferred zsh plugin lists if you want directory-level discovery.
4. Keep the install snippets in this README aligned with the final repo slug.

## License

MIT
