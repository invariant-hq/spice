Skill discovery: builtin skills out of the box, project and compat roots,
shadowing, enablement gates, and validation facts.

The test directory is its own workspace root.

  $ git init -q .

A fresh tree lists the builtin set with the catalog budget.

  $ spice skills list | head -6
  Skills: enabled
    builtin: true  project: true  compat: true
    catalog budget: 8192 bytes (6714 used)
  
  Active skills:
    [1] ocaml-benchmarking  builtin  builtin


A project skill in .spice/skills is discovered and labeled.

  $ mkdir -p .spice/skills/my-skill
  $ cat > .spice/skills/my-skill/SKILL.md <<'EOF'
  > ---
  > description: Project skill.
  > ---
  > Body.
  > EOF
  $ spice skills list | grep -A 1 'my-skill'
    [1] my-skill  project  $TESTCASE_ROOT/.spice/skills/my-skill
        Project skill.

A compat skill shadowing a builtin is reported with the winner.

  $ mkdir -p .claude/skills/ocaml-tidy
  $ cat > .claude/skills/ocaml-tidy/SKILL.md <<'EOF'
  > ---
  > description: Claude copy.
  > ---
  > Body.
  > EOF
  $ spice skills list | grep -A 2 'Inactive'
  Inactive skills:
    ocaml-tidy shadowed by $TESTCASE_ROOT/.claude/skills/ocaml-tidy (builtin)
  

Invalid skills are visible facts, not errors.

  $ mkdir -p .spice/skills/broken
  $ printf 'no frontmatter here\n' > .spice/skills/broken/SKILL.md
  $ spice skills list | grep broken
    broken invalid description_missing ($TESTCASE_ROOT/.spice/skills/broken)
    skill broken ($TESTCASE_ROOT/.spice/skills/broken): frontmatter has no description
  $ spice skills list > /dev/null && echo exit-zero
  exit-zero

Ignored migration frontmatter produces a warning, not a failure.

  $ mkdir -p .spice/skills/ported
  $ cat > .spice/skills/ported/SKILL.md <<'EOF'
  > ---
  > description: Ported skill.
  > allowed-tools:
  >   - Bash
  > context: fork
  > ---
  > Body.
  > EOF
  $ spice skills list | grep 'ignored'
    skill ported: ignored frontmatter keys: allowed-tools, context

Disabling builtin skills removes them; project skills survive.

  $ spice config set skills.builtin false
  $ spice skills list | grep -c 'builtin  builtin'
  0
  [1]
  $ spice skills list | grep -c 'project'
  4
  $ spice config unset skills.builtin

Disabling project skills lists candidates from existence checks only.

  $ spice config set skills.project false
  $ spice skills list | grep 'my-skill'
    my-skill disabled project_skills_disabled ($TESTCASE_ROOT/.spice/skills/my-skill)
  $ spice config unset skills.project

Disabling an individual skill by name excludes it from the catalog and its
budget, whatever root it was found in; the candidate stays visible as
config-disabled.

  $ spice config set skills.disabled '["my-skill"]'
  $ spice skills list | grep 'my-skill'
    my-skill disabled config_disabled ($TESTCASE_ROOT/.spice/skills/my-skill)
  $ spice skills list --json | grep -o '"state":"active"' | wc -l | tr -d ' '
  14
  $ spice config unset skills.disabled

Disabling the surface leaves a one-line answer.

  $ spice config set skills.enabled false
  $ spice skills list
  Skills: disabled (skills.enabled)
  $ spice config unset skills.enabled

Text and JSON agree on the same skills.

  $ spice skills list --json | grep -o '"type":"skills_list"'
  "type":"skills_list"
  $ spice skills list --json | grep -o '"state":"active"' | wc -l | tr -d ' '
  15
