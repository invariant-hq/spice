Apply syntax-aware edits to one OCaml .ml or .mli file. Declarations,
expressions, and types are selected by parsed compiler AST location
rather than text matching, and replacement fragments are parsed before
the file is written — a fragment that does not parse is rejected instead
of corrupting the file.

Use it when text-based editing is fragile: replacing a whole declaration,
targeting one of many textually similar expressions, or transforming a
type. For simple, unique text replacements, the text editor is cheaper.
