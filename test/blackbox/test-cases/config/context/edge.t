Edge cases for workspace-context discovery and projection.

  $ digests () { sed -E 's/sha256:[0-9a-f]+/sha256:HASH/g'; }

A directory named like a candidate is a visible skip fact, not a silent drop,
and does not stop a lower-precedence file from winning.

  $ mkdir AGENTS.override.md
  $ cat > AGENTS.md <<EOF
  > Root instruction.
  > EOF
  $ spice debug context | sed -n '/Active instruction sources:/,/Projection:/p' | digests
  Active instruction sources:
    [1] project AGENTS.md ./AGENTS.md
        bytes: 18 included: 17 digest: sha256:HASH:18
  
  Inactive instruction sources:
    ./AGENTS.override.md skipped not_file
  
  Projection:


  $ rmdir AGENTS.override.md
  $ rm AGENTS.md

An instruction file that is empty after trimming is skipped with a visible
fact.

  $ printf '   \n' > AGENTS.md
  $ spice debug context | sed -n '/Inactive instruction sources:/,/Projection:/p'
  Inactive instruction sources:
    ./AGENTS.md skipped empty
  
  Projection:

  $ rm AGENTS.md

A symlinked candidate whose target stays inside the workspace root is read
normally.

  $ printf 'Linked instruction.\n' > real.md
  $ ln -s real.md AGENTS.md
  $ spice debug prompt | grep 'Linked instruction.'
  Linked instruction.
  $ rm AGENTS.md real.md

A symlinked candidate that resolves outside the workspace root is skipped and
never read.

  $ outside=$(mktemp -d)
  $ printf 'outside text\n' > "$outside/escape.md"
  $ ln -s "$outside/escape.md" AGENTS.md
  $ spice debug context | sed -n '/Inactive instruction sources:/,/Projection:/p'
  Inactive instruction sources:
    ./AGENTS.md skipped outside_workspace
  
  Projection:

  $ spice debug prompt | grep -q 'outside text' || echo absent
  absent
  $ rm AGENTS.md
  $ rm -r "$outside"

A symlinked working directory converges on the canonical activation identity.

  $ mkdir realdir
  $ ln -s realdir linkdir
  $ spice debug prompt --cwd "$PWD/linkdir" | grep 'Current working directory'
  Current working directory: $TESTCASE_ROOT/realdir
  $ spice debug context --cwd "$PWD/linkdir" --json | grep -o '"root_path":"[^"]*"'
  "root_path":"$TESTCASE_ROOT"

Invalid UTF-8 is repaired to U+FFFD with a recorded fact.

  $ printf 'bad \xff bytes\n' > AGENTS.md
  $ spice debug context | grep 'invalid UTF-8'
    ./AGENTS.md: invalid UTF-8 replaced with U+FFFD
  $ spice debug context --json | grep -o '"utf8_repaired":true'
  "utf8_repaired":true
  $ rm AGENTS.md

Budget truncation cuts at a UTF-8 character boundary: no replacement
character is fabricated at the cut.

  $ spice config set instructions.project_max_bytes 5
  $ printf 'ééé\n' > AGENTS.md
  $ spice debug prompt | sed -n '/<INSTRUCTIONS>/,/<\/INSTRUCTIONS>/p'
  <INSTRUCTIONS>
  Instructions from: ./AGENTS.md
  éé
  
  [Instruction file truncated: omitted 2 byte(s) due to the 5-byte project instruction budget]
  </INSTRUCTIONS>

  $ rm AGENTS.md

A later directory's instruction file is visibly omitted once the budget is
exhausted.

  $ printf 'aaaaa' > AGENTS.md
  $ mkdir -p sub
  $ printf 'Sub instruction.\n' > sub/AGENTS.md
  $ spice debug context --cwd "$PWD/sub" | grep -E 'project budget|omitted'
    project budget: 5 bytes (5 used)
    ./sub/AGENTS.md: omitted: project instruction budget exhausted
  $ spice debug prompt --cwd "$PWD/sub" | grep 'Instruction file omitted'
  [Instruction file omitted: project instruction budget exhausted]
  $ spice config unset instructions.project_max_bytes
  $ rm -r sub AGENTS.md

A project whose only instruction file is CLAUDE.md with compatibility
disabled by config is told clearly.

  $ printf 'Claude only.\n' > CLAUDE.md
  $ spice config set instructions.claude_md false
  $ spice debug context | grep -E 'CLAUDE.md disabled|compatibility is disabled'
    ./CLAUDE.md disabled compatibility_disabled
    CLAUDE.md compatibility is disabled; enable instructions.claude_md or migrate to AGENTS.md
  $ spice config unset instructions.claude_md
  $ rm CLAUDE.md

The nested scan skips VCS metadata directories and reports a visible warning
when it stops at the directory cap.

  $ mkdir -p .hg
  $ printf 'hidden\n' > .hg/AGENTS.md
  $ spice debug context | grep -q 'not_activated' || echo none
  none
  $ rm -r .hg

  $ mkdir -p cap
  $ for i in $(seq 1 2100); do mkdir "cap/d$i"; done
  $ spice debug context | grep 'nested instruction scan'
    nested instruction scan stopped at 2048 directories
  $ rm -r cap

Without a .git marker anywhere above the working directory, discovery
considers only the working directory.

  $ work=$(mktemp -d)
  $ canonical_work=$(realpath "$work")
  $ printf 'Tmp instruction.\n' > "$work/AGENTS.md"
  $ spice trust "$work" > /dev/null
  $ spice debug context --cwd "$work" | sed "s#$canonical_work#WORK#g" | sed -n '2,4p'
    cwd: WORK
    root: WORK
    root marker: (none)
  $ spice debug context --cwd "$work" | sed "s#$canonical_work#WORK#g" | grep '\[1\]'
    [1] project AGENTS.md ./AGENTS.md
  $ rm -r "$work"
