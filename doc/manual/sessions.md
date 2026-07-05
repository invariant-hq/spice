# Sessions

Every Spice run happens in a session: a persistent record of the
conversation, the tool calls, and the workspace changes the agent made.

## Storage

Sessions persist per workspace under `.spice/` at the workspace root
(`sessions/`, plus `subagents/` and `todos/`). The directory is created with
`0700` permissions; add `.spice/` to your project's `.gitignore`.

Finished sessions get a best-effort auto-generated title using the small
model. Set `SPICE_AUTO_TITLE=0` to disable.

## Resuming

```sh
spice resume                      # reopen the newest session in this cwd (TUI)
spice run resume SESSION "..."    # extend a session headlessly with a new prompt
spice resume SESSION              # open the TUI on a session by id
```

## Lifecycle commands

```sh
spice session list [--all] [--archived] [--deleted] [-n N] [--json]
spice session show SESSION        # metadata, execution status, and next steps
spice session search QUERY        # search saved session metadata
spice session create [--title T]  # create an empty saved session
spice session rename SESSION TITLE
spice session fork SESSION        # branch a session into a new document
spice session archive SESSION     # hide from default listings
spice session restore SESSION
spice session delete SESSION      # tombstone (asks for confirmation)
spice session export SESSION      # export the session document
spice session compact SESSION     # compact context out-of-band
```

`--all` lists sessions across working directories; by default listings are
scoped to the current one.

## Diff and revert

Spice records every workspace change it authors, per turn. You can inspect
and undo them without touching your own edits:

```sh
spice session diff SESSION --latest          # what the last turn changed
spice session diff SESSION --turn TURN
spice session diff SESSION --path lib/foo.ml

spice session revert SESSION --latest        # preview the revert
spice session revert SESSION --latest --apply
spice session revert SESSION --change ID --apply
spice session revert SESSION --path lib/foo.ml --apply
```

`revert` previews by default and prints the exact `--apply` command when the
plan is clean. Before applying, Spice records a pre-revert checkpoint when a
checkpoint backend is available, so a revert is itself recoverable.
