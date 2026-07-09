Interactive resume: `spice resume` opens the TUI on a saved session. The
headless counterpart is `spice run resume`; these tests only cover what runs
before the TUI needs a terminal (target resolution and flag validation),
since cram has no tty.

With no sessions at all, bare resume opens the TUI home stage and stops at
the terminal boundary in cram.

  $ spice resume
  spice: interactive terminal required to run the TUI
  [1]

--last is the explicit spelling for resolving the newest saved session before
launch.

  $ spice resume --last
  spice: no sessions found; run `spice session list` or start one with `spice`
  [1]

Bare resume does not resolve sessions before launch; the home stage owns that
selection once an interactive terminal is available.

  $ mkdir -p $SPICE_TEST_DATA_HOME/sessions/elsewhere
  $ cat > $SPICE_TEST_DATA_HOME/sessions/elsewhere/session.json <<'JSON'
  > {"version":1,"id":"elsewhere","metadata":{"cwd":"/some/other/project","title":"Elsewhere","status":"active","created_at":1,"updated_at":99999999999999},"events":[]}
  > JSON
  $ spice resume
  spice: interactive terminal required to run the TUI
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

Bare resume still stops at the terminal boundary when a session exists; the
home stage will resolve the target interactively.

  $ spice session create --id idle-session --title Idle
  idle-session
  $ spice resume
  spice: interactive terminal required to run the TUI
  [1]

A unique id prefix resolves to the same target before the TUI starts.

  $ spice resume idle-sess
  spice: interactive terminal required to run the TUI
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

-c resolves the newest session in this directory before the TUI starts.

  $ spice -c
  spice: interactive terminal required to run the TUI
  [1]
