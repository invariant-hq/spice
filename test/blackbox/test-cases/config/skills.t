Skills config keys: enablement booleans, the extra-roots list, and the
catalog byte budget.

  $ git init -q

Defaults are resolved built-ins.

  $ spice config get skills.enabled
  true
  $ spice config get skills.builtin
  true
  $ spice config get skills.project
  true
  $ spice config get skills.compat
  true
  $ spice config get skills.paths
  []
  $ spice config get skills.catalog_max_bytes
  8192

Boolean keys accept exactly true or false.

  $ spice config set skills.enabled false
  $ spice config get skills.enabled
  false
  $ spice config set skills.compat yes
  spice: skills.compat must be true or false
  [2]
  $ spice config get skills.compat
  true

skills.paths is spelled as a JSON array of non-empty strings.

  $ spice config set skills.paths '["/opt/skills", "/srv/pack"]'
  $ spice config get skills.paths
  ["/opt/skills","/srv/pack"]
  $ spice config get --json skills.paths
  ["/opt/skills","/srv/pack"]

Invalid list spellings reject without mutating the stored value.

  $ spice config set skills.paths '/opt/skills'
  spice: skills.paths must be a JSON array of strings, for example ["/a", "/b"]
  [2]
  $ spice config set skills.paths '["/opt/skills", 3]'
  spice: skills.paths must be a string
  [2]
  $ spice config set skills.paths '["", "/srv/pack"]'
  spice: skills.paths must not be empty
  [2]
  $ spice config get skills.paths
  ["/opt/skills","/srv/pack"]

skills.disabled names individual skills to exclude; like skills.paths it is a
JSON array of non-empty strings, and unknown names are preserved.

  $ spice config get skills.disabled
  []
  $ spice config set skills.disabled '["ocaml-benchmarking", "never-seen"]'
  $ spice config get skills.disabled
  ["ocaml-benchmarking","never-seen"]
  $ spice config get --json skills.disabled
  ["ocaml-benchmarking","never-seen"]
  $ spice config set skills.disabled 'ocaml-benchmarking'
  spice: skills.disabled must be a JSON array of strings, for example ["/a", "/b"]
  [2]
  $ spice config get skills.disabled
  ["ocaml-benchmarking","never-seen"]
  $ spice config unset skills.disabled

The catalog budget is a positive integer; zero is not a disable spelling.

  $ spice config set skills.catalog_max_bytes 4096
  $ spice config get skills.catalog_max_bytes
  4096
  $ spice config set skills.catalog_max_bytes 0
  spice: skills.catalog_max_bytes must be positive
  [2]
  $ spice config set skills.catalog_max_bytes nope
  spice: skills.catalog_max_bytes must be an integer
  [2]
  $ spice config get skills.catalog_max_bytes
  4096

Unset returns keys to their built-in defaults, visible in origins.

  $ spice config unset skills.enabled
  $ spice config unset skills.paths
  $ spice config unset skills.catalog_max_bytes
  $ spice config show --origins | grep -A 1 '^skills\.'
  skills.enabled=true
    source: default built-in skills.enabled
  skills.builtin=true
    source: default built-in skills.builtin
  skills.project=true
    source: default built-in skills.project
  skills.compat=true
    source: default built-in skills.compat
  skills.disabled=[]
    source: default built-in skills.disabled
  skills.paths=[]
    source: default built-in skills.paths
  skills.catalog_max_bytes=8192
    source: default built-in skills.catalog_max_bytes
