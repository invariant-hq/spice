Rewrite workspace OCaml expressions by structure: find every expression
matching a `pattern` that is one complete OCaml expression and replace it using
a `template`. The wildcard `__` replaces an expression inside otherwise valid
OCaml grammar; it does not stand for a match clause or make incomplete syntax
valid. The template is
OCaml source with the same metavariable holes as the pattern — `__1`, `__2`,
… — and each hole is filled with the exact source text that metavariable
matched at that site, so comments and formatting inside fragments are preserved.
Example: pattern `match __1 with None -> __2 | Some __3 -> __3`, template
`Option.value __1 ~default:__2`.

Matching is the same structural, formatting-invariant matching as
ocaml_search_expressions (identifiers match as written with path-suffix
tolerance, so it does not see through `open`; use ocaml_find_references when
binding identity matters). Every template metavariable must appear in the
pattern. Replacements are parenthesized as needed and each rewritten site is
re-checked to parse back to the template's structure; a file whose rewrite would
not reparse is skipped and reported, never written broken. Run ocamlformat
afterward to normalize spacing and indentation.

This checks structure, not meaning: a template that introduces a binding whose
body reuses a hole (like `let tmp = __1 in tmp + __2`) is rejected up front,
because the spliced code could shadow a name it referred to. Keep template holes
outside any binder the template introduces.

This applies by default and returns a receipt naming the files it wrote. For a
large or unfamiliar sweep, prefer `dry_run: true` first — it reports the files,
per-site before/after, and the diff without writing, so you can review the blast
radius before applying. `max_sites` bounds the sweep; if there are more matches
than the bound the tool writes nothing and reports the count so you can narrow
`paths`. Files with syntax errors cannot be rewritten and are reported as
skipped. For plain-text replacements or non-OCaml files, use the text editor;
for a single tricky site, ocaml_ast_edit is more surgical.
