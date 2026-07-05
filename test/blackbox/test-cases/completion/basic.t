`spice completion` prints self-contained scripts speaking the cmdliner
completion protocol.

  $ spice completion bash > spice.bash
  $ bash -n spice.bash && echo syntax-ok
  syntax-ok
  $ grep -c "complete -F _spice_cmdliner spice" spice.bash
  1

  $ spice completion zsh | head -1
  #compdef spice

Unknown shells list the vocabulary.

  $ spice completion fish 2>&1 | grep -c "expected one of"
  1
  [124]

The binary side of the protocol answers directly.

  $ spice --__complete --__complete=doc | sed -n '1,5p'
  1
  group
  Subcommands
  item
  doctor
