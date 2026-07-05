Evaluate OCaml toplevel phrases in the current Dune project context. The
tool runs Dune to load the project libraries for a directory, then
evaluates the code in a fresh toplevel process with bounded output and a
timeout.

Use it to check a hypothesis quickly — a function's actual behavior on
an input, a type, an API's shape — without writing a scratch file or a
test. Each call is a fresh process: no state persists between calls, so
make each phrase self-contained.
