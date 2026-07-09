An uncaught fault is surfaced, not swallowed: the process prints a breadcrumb,
writes a crash report with a backtrace, and exits with the internal-error
status (125). SPICE_DEBUG_CRASH injects the fault before any command runs.

  $ SPICE_DEBUG_CRASH=boom spice --version 2> crash-stderr.txt
  [125]

The breadcrumb names the fault and points at the report file (the path carries a
pid and timestamp, so match the stable head and the pointer line):

  $ head -n 1 crash-stderr.txt
  spice crashed: Failure("SPICE_DEBUG_CRASH=boom")
  $ grep -c 'crash report written to .*/xdg-config/spice/crashes/crash-.*\.log$' crash-stderr.txt
  1

The report is persisted under the config home even with logging off, and carries
the fault and a real backtrace:

  $ ls xdg-config/spice/crashes/ | grep -c '^crash-[0-9]*-[0-9]*\.log$'
  1
  $ head -n 1 xdg-config/spice/crashes/crash-*.log
  spice crash report
  $ grep -q '^fault: Failure("SPICE_DEBUG_CRASH=boom")$' xdg-config/spice/crashes/crash-*.log && echo fault-recorded
  fault-recorded
  $ grep -q 'Called from' xdg-config/spice/crashes/crash-*.log && echo has-backtrace
  has-backtrace

A normal invocation writes no crash report and exits cleanly.

  $ spice --version > /dev/null
  $ ls xdg-config/spice/crashes/ | grep -c '^crash-[0-9]*-[0-9]*\.log$'
  1
