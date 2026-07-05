Report the inferred OCaml type at a source position, resolved by Merlin
in the current Dune project context — the type the compiler sees, not a
guess from reading the code.

Reach for this when a build error blames a type mismatch: ask for the
type at the flagged position, and raise max_enclosings to also get the
enclosing expression's type in the same call. Input positions use
1-based lines and 0-based byte columns, as rendered by read_file.

If a returned type is an unhelpful alias, re-call with a higher
verbosity to unfold it. Set documentation:true to also fetch the
entity's odoc comment. Prefer this over reading source to answer "what
is this expression's type".
