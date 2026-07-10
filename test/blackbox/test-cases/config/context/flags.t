Instruction flags override config enablement for one invocation.

  $ digests () { sed -E 's/(rendered digest: sha256:[0-9a-f]+):[0-9]+/\1:LEN/; s/("rendered_digest":"sha256:[0-9a-f]+):[0-9]+/\1:LEN/; s/sha256:[0-9a-f]+/sha256:HASH/g'; }
  $ cat > AGENTS.md <<EOF
  > Root instruction.
  > EOF

--no-project-instructions prevents reading project-controlled text: candidates
are listed from existence checks only, disabled, with no content facts.

  $ spice debug context --no-project-instructions | digests
  Workspace:
    cwd: $TESTCASE_ROOT
    root: $TESTCASE_ROOT
    root marker: .git
    global instructions: enabled (default)
    project instructions: disabled (flag)
    claude compatibility: enabled (default)
    project budget: 32768 bytes (0 used)
  
  Active instruction sources:
    (none)
  
  Inactive instruction sources:
    ./AGENTS.md disabled project_instructions_disabled
  
  Projection:
    rendered digest: sha256:HASH:LEN
  
  Warnings:
    (none)


A flag beats config: with project instructions disabled by config,
--project-instructions re-enables them for one run and the origin says so.

  $ spice config set instructions.project false
  $ spice debug context | grep -E 'project instructions:|disabled '
    project instructions: disabled (config)
    ./AGENTS.md disabled project_instructions_disabled

  $ spice debug context --project-instructions | grep -E 'project instructions:|^\s+\[1\]'
    project instructions: enabled (flag)
    [1] project AGENTS.md ./AGENTS.md

  $ spice config unset instructions.project

--no-instructions disables global and project instructions together.

  $ mkdir -p "$XDG_CONFIG_HOME/spice"
  $ cat > "$XDG_CONFIG_HOME/spice/AGENTS.md" <<EOF
  > Global instruction.
  > EOF

  $ spice debug context --no-instructions | grep -E 'instructions:|disabled '
    global instructions: disabled (flag)
    project instructions: disabled (flag)
    $TESTCASE_ROOT/xdg-config/spice/AGENTS.md disabled instructions_disabled
    ./AGENTS.md disabled project_instructions_disabled

Contradictory flags are usage errors.

  $ spice run --project-instructions --no-project-instructions prompt
  spice: --project-instructions cannot be combined with an
         instruction-disabling flag
  [124]

  $ spice debug context --project-instructions --no-instructions
  spice: --project-instructions cannot be combined with an
         instruction-disabling flag
  [124]
