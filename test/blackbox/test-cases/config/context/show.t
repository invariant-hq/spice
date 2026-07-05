Spice debug context reports workspace facts, instruction sources in
deterministic order, the projection identity, and warnings.

The testcase pins its own workspace root so discovery does not walk up into
the repository that runs the tests.

  $ mkdir .git
  $ digests () { sed -E 's/(rendered digest: sha256:[0-9a-f]+):[0-9]+/\1:LEN/; s/("rendered_digest":"sha256:[0-9a-f]+):[0-9]+/\1:LEN/; s/sha256:[0-9a-f]+/sha256:HASH/g'; }

With no instruction files, workspace facts and a stable projection are still
reported.

  $ spice debug context | digests
  Workspace:
    cwd: $TESTCASE_ROOT
    root: $TESTCASE_ROOT
    root marker: .git
    global instructions: enabled (default)
    project instructions: enabled (default)
    claude compatibility: enabled (default)
    project budget: 32768 bytes (0 used)
  
  Active instruction sources:
    (none)
  
  Inactive instruction sources:
    (none)
  
  Projection:
    rendered digest: sha256:HASH:LEN
  
  Warnings:
    (none)


A root AGENTS.md becomes an active project source with byte and digest facts.

  $ cat > AGENTS.md <<EOF
  > Root instruction.
  > EOF

  $ spice debug context | digests
  Workspace:
    cwd: $TESTCASE_ROOT
    root: $TESTCASE_ROOT
    root marker: .git
    global instructions: enabled (default)
    project instructions: enabled (default)
    claude compatibility: enabled (default)
    project budget: 32768 bytes (18 used)
  
  Active instruction sources:
    [1] project AGENTS.md ./AGENTS.md
        bytes: 18 included: 17 digest: sha256:HASH:18
  
  Inactive instruction sources:
    (none)
  
  Projection:
    rendered digest: sha256:HASH:LEN
  
  Warnings:
    (none)


A global AGENTS.md in the config home is listed first and labeled global.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/AGENTS.md" <<EOF
  > Global instruction.
  > EOF

  $ spice debug context | grep -E '^\s+\[[0-9]\]'
    [1] global AGENTS.md $TESTCASE_ROOT/xdg-config/spice/AGENTS.md
    [2] project AGENTS.md ./AGENTS.md

  $ rm "$XDG_CONFIG_HOME/spice/AGENTS.md"

AGENTS.override.md wins over AGENTS.md within one directory and the loser is
reported as shadowed.

  $ cat > AGENTS.override.md <<EOF
  > Override instruction.
  > EOF

  $ spice debug context | digests | sed -n '/Active instruction sources:/,/Projection:/p'
  Active instruction sources:
    [1] local_override AGENTS.override.md ./AGENTS.override.md
        bytes: 22 included: 21 digest: sha256:HASH:22
  
  Inactive instruction sources:
    ./AGENTS.md shadowed shadowed_by_override
  
  Projection:


  $ rm AGENTS.override.md

CLAUDE.md is loaded by default when it is the only candidate, and is shadowed
by AGENTS.md in the same directory.

  $ cat > CLAUDE.md <<EOF
  > Claude instruction.
  > EOF

  $ spice debug context | sed -n '/Inactive instruction sources:/,/Projection:/p'
  Inactive instruction sources:
    ./CLAUDE.md shadowed shadowed_by_agents
  
  Projection:


  $ rm AGENTS.md
  $ spice debug context | grep -E '^\s+\[[0-9]\]'
    [1] compatibility CLAUDE.md ./CLAUDE.md

  $ rm CLAUDE.md

Budget truncation is deterministic and visible as a warning and in the budget
facts.

  $ awk 'BEGIN { for (i = 0; i < 33000; i++) printf "a" }' > AGENTS.md
  $ spice debug context | grep -E 'project budget|truncated'
    project budget: 32768 bytes (32768 used)
    ./AGENTS.md: truncated: omitted 232 byte(s) by the project instruction budget

  $ rm AGENTS.md

Nested AGENTS.md files below the cwd are reported as inactive audit facts and
do not affect the projection.

  $ mkdir -p sub
  $ cat > sub/AGENTS.md <<EOF
  > Nested instruction.
  > EOF

  $ spice debug context | sed -n '/Inactive instruction sources:/,/Projection:/p'
  Inactive instruction sources:
    ./sub/AGENTS.md not_activated nested_not_activated
  
  Projection:


The JSON view describes the same workspace facts, sources, projection
identity, and warnings as the text view.

  $ spice debug context --json | digests
  {"schema_version":1,"type":"context_show","workspace":{"cwd":"$TESTCASE_ROOT","cwd_path":"$TESTCASE_ROOT","root":"$TESTCASE_ROOT","root_path":"$TESTCASE_ROOT","root_marker":".git","global_instructions":{"enabled":true,"origin":"default"},"project_instructions":{"enabled":true,"origin":"default"},"claude_compatibility":{"enabled":true,"origin":"default"},"budget":{"total":32768,"used":0},"nested_scan":"complete"},"sources":[{"path":"$TESTCASE_ROOT/sub/AGENTS.md","display_path":"./sub/AGENTS.md","kind":"project","state":"not_activated","reason":"nested_not_activated"}],"projection":{"rendered_digest":"sha256:HASH:LEN"},"warnings":[]}
