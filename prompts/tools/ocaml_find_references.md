Find semantic references to the OCaml entity at a file position using
Merlin occurrences. The query is identity-based, not a textual grep: it
finds uses of that specific binding, not strings that happen to match.

Prefer this over search_text when assessing a rename or a signature
change's blast radius. Input is a workspace OCaml file path plus a
1-based line and 0-based byte column. Project-wide scope depends on the
Merlin/Dune occurrence index; stale occurrences are excluded by default.
