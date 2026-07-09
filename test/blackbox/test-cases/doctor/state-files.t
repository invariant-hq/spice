Machine-local diagnostics use state home, independently from configuration and
durable session data.

The TUI diverts enabled diagnostics before it checks terminal availability, so
this non-PTY test can inspect the per-process file and latest pointer.

  $ SPICE_LOG=debug spice >/dev/null 2>&1
  [1]
  $ find "$XDG_STATE_HOME/spice/logs" -name '*.log' | wc -l | tr -d ' '
  1
  $ test -f "$XDG_STATE_HOME/spice/logs/latest.json" && echo latest
  latest
  $ grep -o '"run_id":"[^"]*"' "$XDG_STATE_HOME/spice/logs/latest.json" | sed -E 's/:"[^"]*"/:"$RUN"/'
  "run_id":"$RUN"
  $ grep -q '\[run=' "$XDG_STATE_HOME/spice/logs/"*.log && echo tagged
  tagged
  $ test ! -e "$XDG_CONFIG_HOME/spice/spice.log" && echo no-config-log
  no-config-log

An explicit log destination must be absolute and remains the headless override.

  $ SPICE_LOG=info SPICE_LOG_FILE=relative.log spice --version
  spice: SPICE_LOG_FILE: must be an absolute path
  [124]
  $ SPICE_LOG=info SPICE_LOG_FILE="$PWD/explicit.log" spice --version >/dev/null
  $ test -s explicit.log && echo explicit
  explicit
