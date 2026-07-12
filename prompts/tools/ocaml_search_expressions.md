Search workspace OCaml sources for code shaped like one complete OCaml
expression. The wildcard `__` replaces an expression inside otherwise valid
OCaml grammar; it does not stand for a match clause or make incomplete syntax
valid. Matching is structural, not textual: it is invariant to formatting and
line breaks, `__1`/`__2` force structurally equal sub-expressions, pattern
arguments may omit call arguments, `f ?arg:PRESENT` / `f ?arg:MISSING`
constrain optional arguments, and match/try/function clauses and record fields
match as order-independent sets. Example: `List.rev __ @ __` or
`match __ with None -> __ | Some __1 -> Some __1`.

Matching is syntactic — identifiers match as written (with path-suffix
tolerance: `filter` matches `List.filter`), so it does not see through
`open` or module aliases; use ocaml_find_references when binding
identity matters. Sources are parsed directly, so it works on unbuilt
code, but files with syntax errors cannot be searched and are reported
as skipped. Type-constrained patterns like `(__ : t)` are not
supported. For plain text or regex searches, and for non-OCaml files,
use search_text.
