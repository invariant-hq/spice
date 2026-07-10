# Sessions

Every Spice run happens in a session, which associates the conversation and
tool calls with related workspace changes and workflow artifacts. The saved
session document itself contains session metadata and the semantic event log.

## Storage

Sessions are global durable data, not project files. On Unix they default to
`$XDG_DATA_HOME/spice` (or `~/.local/share/spice`); `SPICE_DATA_HOME` overrides
the complete root. Session documents live at
`sessions/<percent-escaped-session-id>/session.json`, while plans remain
standalone at
`plans/<percent-escaped-session-id>/<percent-escaped-plan-id>.json`. Todos,
goals, subagent records, blobs, and workspace mutation, checkpoint, and review
facts are sibling stores correlated by session and turn ids; they are not
session events.

Directories use `0700` and files use `0600`. `spice session export` serializes
only the session document (or a text/Markdown projection of it). It does not
include any sibling-store artifacts, so an export is not a backup of the
mutation evidence required by `session diff`, `session revert`, or
`rewind --revert-fs`.

The project `.spice/` directory is reserved for inputs that may be shared with
the repository: `config.json`, the gitignored `config.local.json`, and project
skills. Ordinary runs do not create project-local session state.

Finished sessions get a best-effort auto-generated title using the small
model. Set `SPICE_AUTO_TITLE=0` to disable.

## Resuming

```sh
spice resume                      # reopen the newest session in this cwd (TUI)
spice run resume SESSION "..."    # extend a session headlessly with a new prompt
spice resume SESSION              # open the TUI on a session by id
```

Commands that take a session id accept a unique id prefix. Where supported,
`--last` targets the newest session in the current working directory.
An explicit id can be used from any directory; continuation executes in the
canonical cwd recorded by the session. An explicit `--cwd` must match it.

## Lifecycle commands

```sh
spice session list [--all] [--archived] [--deleted] [-n N] [--json]
spice session show SESSION        # metadata, execution status, and next steps
spice session search QUERY        # search saved session metadata
spice session create [--title T]  # create an empty saved session
spice session rename SESSION TITLE
spice session fork SESSION --id CHILD [--title T]
spice session rewind SESSION --to-turn TURN --id CHILD [--after] [--revert-fs]
spice session archive SESSION     # hide from default listings
spice session restore SESSION
spice session delete SESSION      # tombstone (asks for confirmation)
spice session export SESSION [--format json|text|markdown]
spice session compact SESSION     # compact context out-of-band
```

`--all` lists sessions across working directories; by default listings are
scoped to the current one.

`fork` copies the whole parent into a new child and leaves the parent
unchanged. `rewind` is fork-at-a-turn-boundary: `--before` (the default) drops
the named turn and everything after it; `--after` keeps the named turn and
drops only later turns. `--revert-fs` also attempts an all-or-nothing revert of
the dropped turns' Spice-authored workspace changes. A stale file or missing
mutation record refuses that filesystem revert without discarding the new
transcript child.

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
