Catalog budget: descriptions trim with a visible ellipsis before any name
drops; builtin descriptions never trim; warnings report the trimming.

  $ git init -q .
  $ long=$(printf 'x%.0s' $(seq 1 400))
  $ for name in alpha beta gamma; do
  >   mkdir -p ".spice/skills/$name"
  >   printf -- '---\ndescription: %s %s\n---\nbody\n' "$name" "$long" > ".spice/skills/$name/SKILL.md"
  > done

Within a large budget nothing trims.

  $ spice skills list | grep -c 'catalog over budget'
  0
  [1]

Under a small budget the project descriptions trim and warnings name them;
builtin descriptions stay full.

  $ spice config set skills.catalog_max_bytes 3000
  $ spice skills list | grep 'over budget'
    skill catalog over budget: descriptions dropped for non-builtin skills
  $ spice skills list --json | grep -o '"trimmed":\[[^]]*\]'
  "trimmed":[]
  $ spice debug tools --json | grep -o 'alpha[^"]*' | head -1
  alpha\n- beta\n- gamma\n- ocaml-benchmarking: Guides setting up and maintaining benchmark suites for OCaml code. Use when adding benchmarks, setting up a bench suite, tracking performance regressions, wiring benchmarks into dune runtest, or proving that an optimization holds. Triggers on phrases like \

A budget too small for descriptions falls back to names-only for
non-builtin skills, still listing every name.

  $ spice config set skills.catalog_max_bytes 2450
  $ spice skills list | grep 'over budget'
    skill catalog over budget: descriptions dropped for non-builtin skills
  $ spice skills list --json | grep -o '"names_only":true'
  "names_only":true
  $ spice config unset skills.catalog_max_bytes
