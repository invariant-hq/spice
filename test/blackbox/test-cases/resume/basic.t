Interactive resume: `spice resume` opens the TUI on a saved session. The
headless counterpart is `spice run resume`; these tests only cover what runs
before the TUI needs a terminal (target resolution and flag validation),
since cram has no tty.

With no sessions at all, bare resume says so and points at the TUI.

  $ spice resume
  spice: no sessions found; run `spice session list` or start one with `spice`
  [1]

--last is the explicit spelling of the same default.

  $ spice resume --last
  spice: no sessions found; run `spice session list` or start one with `spice`
  [1]

When the newest session lives in another directory and none live here,
resume refuses with a copy-pasteable cd command naming the TUI verb.

  $ mkdir -p .spice/sessions/elsewhere
  $ cat > .spice/sessions/elsewhere/session.json <<'JSON'
  > {"version":1,"id":"elsewhere","metadata":{"cwd":"/some/other/project","title":"Elsewhere","status":"active","created_at":1,"updated_at":99999999999999},"events":[]}
  > JSON
  $ spice resume
  spice: no session in $TESTCASE_ROOT; most recent session is 'elsewhere' in /some/other/project; run: cd '/some/other/project' && spice resume 'elsewhere'
  [1]

SESSION and --last are mutually exclusive.

  $ spice resume some-session --last
  spice: choose SESSION or --last, not both
  [2]

A named session resolves against the store before the TUI starts, so bad
ids get their answer without a terminal, and unique id prefixes resolve.

  $ spice resume missing
  spice: session not found: missing
  [1]

Bare resume with a session in this directory resolves it (no "no sessions"
refusal) and then stops at the same terminal boundary, which proves the
selection happened before the TUI started.

  $ spice session create --id idle-session --title Idle
  idle-session
  $ spice resume
  spice: interactive terminal required; use `spice run PROMPT`, `spice run resume SESSION PROMPT`, or `spice session list`
  [1]

A unique id prefix resolves to the same target before the TUI starts.

  $ spice resume idle-sess
  spice: interactive terminal required; use `spice run PROMPT`, `spice run resume SESSION PROMPT`, or `spice session list`
  [1]

Composer text flags are mutually exclusive, checked before any launch.

  $ spice resume idle-session --draft "d" --prompt "p"
  spice: choose only one of --draft or --prompt
  [2]

The default command's continuation shortcut mirrors resume and rejects an
explicit session at the same time.

  $ spice --continue --session idle-session
  spice: choose only one of --continue or --session
  [2]

-c resolves the newest session in this directory before the TUI starts, like
bare resume.

  $ spice -c
  spice: interactive terminal required; use `spice run PROMPT`, `spice run resume SESSION PROMPT`, or `spice session list`
  [1]
