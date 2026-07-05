Read the current OCaml compiler and Dune errors and warnings for the
workspace, with source locations.

Check diagnostics after edits and before claiming a change done — a
clean diagnostic set is the OCaml verification baseline. The tool
returns the latest set observed from the workspace's running Dune
instance; it does not start Dune or block waiting for a rebuild. If it
reports unavailable, no Dune instance is currently visible — fall back
to building through the shell.
