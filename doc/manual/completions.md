# Shell completions

`spice completion SHELL` prints a self-contained completion script for
`bash`, `zsh`, or `pwsh`. The script drives the binary's cmdliner completion
protocol, so commands, subcommands, and options complete without any
external helper.

## zsh

```sh
mkdir -p ~/.local/share/zsh/site-functions
spice completion zsh > ~/.local/share/zsh/site-functions/_spice
```

and make sure the directory is on `fpath` before `compinit` in `~/.zshrc`:

```sh
fpath=(~/.local/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit
```

## bash

```sh
mkdir -p ~/.local/share/bash-completion/completions
spice completion bash > ~/.local/share/bash-completion/completions/spice
```

The `bash-completion` package sources it on demand.

## PowerShell

```powershell
spice completion pwsh >> $PROFILE
```

## Verifying

`spice --__complete --__complete=se` prints the raw completion protocol
(one `item` per candidate); if that lists `session`, the binary side works
and any remaining issue is shell setup.
