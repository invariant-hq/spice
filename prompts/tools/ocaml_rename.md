Rename an OCaml binding and every reference to it in one atomic, project-wide
edit, using Merlin renaming-scope occurrences. This is a semantic rename keyed
to binding identity, not a textual find-replace: it rewrites uses of that
specific value, type, constructor, module, or record field — across `.ml` and
`.mli` — and never touches unrelated names that merely match as text.

Input is a workspace OCaml file path, a 1-based line and 0-based byte column on
the identifier, and the new_name. It applies the rename directly and returns a
receipt; set dry_run true to instead report the planned edit — the files,
per-file occurrence counts, and the old and new names — without writing, e.g.
to check blast radius or show the user a plan before applying. Project-wide
occurrences depend on the Merlin/Dune index (dune build @ocaml-index). The
rename refuses rather than half-apply if the index looks stale or any
reference no longer holds the old name. It does not check whether new_name
collides with an existing binding — run ocaml_dune_diagnostics after applying.
It also refuses (rather than guess) at labelled-argument and record-field pun
sites such as `~x` and `{ x }`; edit those by hand. Prefer this over search_text
plus manual edits for any rename.
