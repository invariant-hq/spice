Locate an OCaml identifier's definition, declaration, or type definition
using Merlin semantics in the current Dune project context.

Prefer this over textual search when you need where a name is actually
defined — it resolves through opens, includes, aliases, and shadowing,
where grepping guesses. Input positions use 1-based lines and 0-based
byte columns, as rendered by read_file.
