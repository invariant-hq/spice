Spice config edits preserve unknown members nested inside known sections.

This pins the edge preservation.t does not cover: a known section object
(here [skills]) carrying members the current schema does not declare. An
edit that rewrites the file must carry them through untouched.

Seed user config with a known section holding both a known and an unknown
member.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<EOF
  > {"skills":{"enabled":true,"experimental_rank":3},"model":"openai/old"}
  > EOF

Setting an unrelated known field preserves the unknown nested member.

  $ spice config set model openai/gpt-5.5
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"model":"openai/gpt-5.5","skills":{"enabled":true,"experimental_rank":3}}

Setting the known member inside the section preserves its unknown sibling.

  $ spice config set skills.enabled false
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"model":"openai/gpt-5.5","skills":{"enabled":false,"experimental_rank":3}}

Unsetting the known member keeps the section alive for its unknown sibling.

  $ spice config unset skills.enabled
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"model":"openai/gpt-5.5","skills":{"experimental_rank":3}}
