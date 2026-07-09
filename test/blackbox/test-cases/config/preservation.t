Spice config edits preserve unknown JSON fields.

  $ git init -q

Seed user config with known and unknown fields.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/config.json" <<EOF
  > {"unknown":true,"model":"openai/old","providers":{"openai":{"base_url":"https://old.example/v1","organization":"org_123"}}}
  > EOF

Setting a known top-level field preserves unknown top-level fields and provider
fields.

  $ spice config set model openai/gpt-5.5
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true,"model":"openai/gpt-5.5","providers":{"openai":{"base_url":"https://old.example/v1","organization":"org_123"}}}

Setting a provider field preserves unknown provider fields.

  $ spice config set providers.openai.base_url https://new.example/v1
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true,"model":"openai/gpt-5.5","providers":{"openai":{"base_url":"https://new.example/v1","organization":"org_123"}}}

Unsetting known fields preserves unknown fields.

  $ spice config unset model
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true,"providers":{"openai":{"base_url":"https://new.example/v1","organization":"org_123"}}}

  $ spice config unset providers.openai.base_url
  $ cat "$XDG_CONFIG_HOME/spice/config.json"
  {"unknown":true,"providers":{"openai":{"organization":"org_123"}}}
