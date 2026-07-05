Skill show: provenance, content facts, and failures.

  $ git init -q .
  $ mkdir -p .spice/skills/demo
  $ cat > .spice/skills/demo/SKILL.md <<'EOF'
  > ---
  > name: Demo Skill
  > description: A demo.
  > ---
  > Do the demo.
  > EOF
  $ printf 'extra notes\n' > .spice/skills/demo/notes.md

  $ spice skills show demo
  name: demo
  display name: Demo Skill
  kind: project
  origin: $TESTCASE_ROOT/.spice/skills/demo
  digest: sha256:821403992feee149c4c064bab57bedafd9750db22d8ec252ede97adf60fc02ae:59
  bytes: 59
  resources:
    notes.md
  
  ---
  name: Demo Skill
  description: A demo.
  ---
  Do the demo.
  

Unknown and invalid names exit non-zero with the available set.

  $ spice skills show nope 2>&1 | head -1
  spice: unknown skill "nope"; available skills: demo, ocaml-benchmarking, ocaml-concurrency, ocaml-debug, ocaml-doc, ocaml-dune, ocaml-ffi, ocaml-library-design, ocaml-module-design, ocaml-perf, ocaml-project-setup, ocaml-release, ocaml-testing, ocaml-tidy
  [1]
  $ spice skills show nope > /dev/null 2>&1; echo "exit=$?"
  exit=1
  $ spice skills show 'Bad Name' > /dev/null 2>&1; echo "exit=$?"
  exit=1

JSON carries the same facts.

  $ spice skills show --json demo | grep -o '"type":"skills_show"'
  "type":"skills_show"
  $ spice skills show --json demo | grep -o '"name":"demo"'
  "name":"demo"
  $ spice skills show --json demo | grep -o '"state":"active"'
  "state":"active"
