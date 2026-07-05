Get the API surface — signatures and documentation — of OCaml code by name or
by path, for anything in this project's module universe: your own workspace
libraries and the project's locked dependencies. Reads the exact sources this
project links, so answers match the code that will compile — no network, no
guessing.

Use it before writing or reading code against a module you don't have in front
of you, instead of guessing a signature or reading a whole .mli. One `query`,
four forms, selected by shape:

- a workspace file path (has a / or ends in .ml/.mli): `lib/foo/bar.ml` ->
  outline that file (values, types, modules), Merlin-accurate, works on files
  you're mid-edit.
- a library name (lowercase, dotted like dune's `libraries` field): `eio`,
  `eio.unix`, `spice_permission` -> overview: top-level modules, sublibraries,
  synopsis.
- a module path (Capitalized): `Eio.Path`, `Jsont.Object` -> that module's
  outline with doc comments. Nested module bodies collapse to a count; query
  the nested path to expand.
- an identifier (Capitalized path ending lowercase): `Eio.Path.load` -> just
  that item's signature and doc.

`scope` (workspace | deps | any, default any) breaks ties when a name exists in
both your workspace and a dependency. Output states provenance — `workspace file
<path>`, `workspace library <name>`, or `<pkg>@<version> (<hash>)` — so evidence
is auditable. Unknown names return close matches or the real module list.
Libraries the project does NOT depend on are out of scope (use web_fetch on
ocaml.org for those). When the outline isn't enough, follow up with read_file on
the reported source path.
