Spice debug tools prints the complete model-visible tool catalog for run
requests: every declaration a run sends to the provider, with description text
and input schema. This snapshot is the review surface for tool prompts: any
change to prompts/tools/* or to an input schema shows up in this diff.

The file-mutation editor family is model-conditional. A GPT-family model is
trained on the apply_patch format, so it receives apply_patch alone; the header
line states the resolved family and why. This is the prompt-review surface for
the apply_patch family.

  $ spice debug tools --model openai/gpt-5.5
  Editor family: apply-patch (capability)
  
  ## read_file
  
  Read what is at a path inside the workspace: a file's text, or a directory's
  entries.
  
  Files:
  - UTF-8 text comes back numbered. Use offset and limit to read just the range
    you need from a large file — avoid re-reading whole files for one section —
    and max_bytes to bound very large reads.
  - When the complete file is read, the result includes a file identity: a token
    you can pass as if_identity to an editing tool that accepts one, so a
    concurrent change rejects your mutation instead of clobbering it.
  - Reading several known files? Issue the read_file calls in parallel.
  
  Directories:
  - Reading a directory lists its immediate entries, one per line, sorted by kind
    then name, with a trailing slash on subdirectories. Ordinary dotfiles are
    included; VCS metadata is omitted. offset and limit page the entries the same
    way they page a file's lines; max_bytes and if_identity do not apply.
  - To explore a tree by name pattern use glob; to find content use search_text.
  
  Binary files, special files, and paths outside the workspace are rejected.
  
  Input schema: {"type":"object","properties":{"max_bytes":{"type":"integer","minimum":0,"description":"Maximum UTF-8 bytes to return. Applies to file reads only."},"limit":{"type":"integer","minimum":1,"description":"Maximum lines to return, or directory entries. Defaults to the end of the file, or 200 entries."},"offset":{"type":"integer","minimum":1,"description":"1-based first line to return, or first directory entry. Defaults to the start."},"path":{"type":"string","description":"Workspace-relative or workspace-contained absolute path to read (a file or a directory)."}},"required":["path"],"additionalProperties":false}
  
  ## search_text
  
  Search UTF-8 file contents inside the workspace with a ripgrep-style
  regex, for example "let +normalize\b".
  
  Modes: the default returns matching file paths only; count returns
  per-file matching-line counts; matches returns line-numbered snippets.
  Search roots may be files or directories; directory searches are
  recursive, deterministic, respect standard ignore files, and skip binary
  files and VCS metadata. Output paths are workspace-relative.
  
  To find files by name, use glob. For an open-ended investigation needing
  several rounds of searching and reading, spawn an explore subagent
  instead of searching piecemeal.
  
  Input schema: {"type":"object","properties":{"pattern":{"type":"string","description":"Ripgrep/Rust regular expression to search for in UTF-8 text files."},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Workspace-relative or workspace-contained absolute file or directory roots. Defaults to the workspace current directory."},"glob":{"type":"string","description":"Optional file glob filter, for example \"*.ml\" or \"**/*.ts\"."},"mode":{"type":"string","enum":["files","count","matches"],"description":"Result mode. files returns paths, count returns per-file matching-line counts, matches returns line snippets. Defaults to files."},"case_insensitive":{"type":"boolean","description":"Use case-insensitive regular-expression matching."},"context_lines":{"type":"integer","minimum":0,"maximum":5,"description":"Symmetric context lines around matches. Valid only in matches mode."},"offset":{"type":"integer","minimum":1,"description":"1-based first result entry to return. Defaults to 1."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum number of result entries to return. Defaults to 100."}},"required":["pattern"],"additionalProperties":false}
  
  ## glob
  
  Find files inside the workspace by ripgrep glob pattern, for example
  "**/*.mli" or "lib/**/dune".
  
  Discovery is recursive, respects standard ignore files, includes ordinary
  dotfiles, and excludes VCS metadata. Results are workspace-relative
  paths, paginated with a one-based offset; use sort=modified for newest
  first. To search file contents rather than names, use search_text. For
  an open-ended hunt that will take several rounds of globbing and
  searching, spawn an explore subagent instead.
  
  Input schema: {"type":"object","properties":{"pattern":{"type":"string","description":"Ripgrep glob pattern for workspace-relative file paths, for example \"**/*.ml\" or \"**/*.{ts,tsx}\"."},"path":{"type":"string","minLength":1,"description":"Workspace-relative or workspace-contained absolute directory root. Defaults to the workspace root."},"offset":{"type":"integer","minimum":1,"description":"1-based first file to return. Defaults to 1."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum number of files to return. Defaults to 100."},"sort":{"type":"string","enum":["path","modified"],"description":"Ordering policy. path is deterministic workspace-relative path order; modified is newest files first with path as tie-breaker."}},"required":["pattern"],"additionalProperties":false}
  
  ## apply_patch
  
  Apply one patch to UTF-8 text files in the workspace. Use this for every
  edit: a single targeted replacement, several hunks in one file, edits
  spanning multiple files, or adding, deleting, and moving files in one
  atomic step.
  
  The patch uses the envelope
  
    *** Begin Patch
    *** Update File: path/to/file.ml
    @@ let nearest_enclosing_header
     context line
    -old line
    +new line
     context line
    *** End Patch
  
  with *** Add File:, *** Delete File:, and optional *** Move to: sections.
  Paths are workspace-root relative, never absolute.
  
  Context craft: give about three lines of context above and below each
  change; when that does not uniquely locate the hunk, add an @@ line
  naming the enclosing definition. Missing or ambiguous context rejects
  the whole patch — nothing is partially applied.
  
  Also rejected: absolute paths, symlinks, directories, binary files,
  invalid UTF-8, duplicate outputs, and add or move destinations that
  already exist. On success, do not re-read the files to confirm; a patch
  that does not apply fails loudly.
  
  Input schema: {"type":"object","properties":{"patch":{"type":"string","description":"Complete Codex-style patch text. Patch paths must be workspace-root relative."}},"required":["patch"],"additionalProperties":false}
  
  ## ocaml_ast_edit
  
  Apply syntax-aware edits to one OCaml .ml or .mli file. Declarations,
  expressions, and types are selected by parsed compiler AST location
  rather than text matching, and replacement fragments are parsed before
  the file is written — a fragment that does not parse is rejected instead
  of corrupting the file.
  
  Use it when text-based editing is fragile: replacing a whole declaration,
  targeting one of many textually similar expressions, or transforming a
  type. For simple, unique text replacements, the text editor is cheaper.
  
  Input schema: {"type":"object","properties":{"path":{"type":"string","minLength":1,"description":"Workspace-relative or workspace-contained OCaml source path."},"file_kind":{"type":"string","enum":["implementation","interface","ml","mli"],"description":"implementation/ml or interface/mli. Defaults from the file extension."},"if_identity":{"type":"string","minLength":1,"description":"Complete-file identity from a previous complete read."},"edits":{"type":"array","items":{"type":"object","properties":{"op":{"type":"string","enum":["replace","insert_before","insert_after","delete"]},"selector":{"type":"object","properties":{"mode":{"type":"string","enum":["item","enclosing","exact"]},"path":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Qualified item path components, for example [\"M\",\"answer\"]. Required when mode is item."},"item_kind":{"allOf":[{"type":"string","enum":["value","type","module","module_type","exception","external","open","include","class","class_type","extension","eval"]}],"description":"Optional item kind filter for item selectors."},"occurrence":{"type":"integer","minimum":1,"description":"1-based occurrence when an item path matches multiple declarations. Defaults to 1."},"kind":{"type":"string","enum":["item","expression","type"],"description":"AST node kind for enclosing and exact selectors."},"node_item_kind":{"allOf":[{"type":"string","enum":["value","type","module","module_type","exception","external","open","include","class","class_type","extension","eval"]}],"description":"Optional item-kind filter when kind is item for enclosing or exact selectors."},"line":{"type":"integer","minimum":1,"description":"1-based cursor line for enclosing selectors."},"column":{"type":"integer","minimum":0,"description":"0-based byte cursor column for enclosing selectors."},"start_line":{"type":"integer","minimum":1,"description":"1-based exact range start line."},"start_column":{"type":"integer","minimum":0,"description":"0-based byte exact range start column."},"end_line":{"type":"integer","minimum":1,"description":"1-based exact range end line."},"end_column":{"type":"integer","minimum":0,"description":"0-based byte exact range end column."}},"required":["mode"],"additionalProperties":false},"text":{"type":"string","minLength":1,"description":"Replacement or insertion OCaml fragment. Omit for delete."}},"required":["op","selector"],"additionalProperties":false},"minItems":1}},"required":["path","edits"],"additionalProperties":false}
  
  ## ocaml_eval
  
  Evaluate OCaml toplevel phrases in the current Dune project context. The
  tool runs Dune to load the project libraries for a directory, then
  evaluates the code in a fresh toplevel process with bounded output and a
  timeout.
  
  Use it to check a hypothesis quickly — a function's actual behavior on
  an input, a type, an API's shape — without writing a scratch file or a
  test. Each call is a fresh process: no state persists between calls, so
  make each phrase self-contained.
  
  Input schema: {"type":"object","properties":{"code":{"type":"string","description":"Non-empty OCaml toplevel phrase text to evaluate."},"dir":{"type":"string","description":"Workspace-relative or workspace-contained absolute Dune directory. Defaults to the workspace root."},"timeout_ms":{"type":"integer","minimum":1,"description":"Optional total timeout in milliseconds for setup and evaluation, bounded by host configuration."}},"required":["code"],"additionalProperties":false}
  
  ## ocaml_rename
  
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
  
  Input schema: {"type":"object","properties":{"path":{"type":"string","minLength":1,"description":"Workspace-relative or workspace-contained absolute OCaml source file path."},"line":{"type":"integer","minimum":1,"description":"1-based source line of the identifier cursor."},"column":{"type":"integer","minimum":0,"description":"0-based byte column in the source line, matching OCaml/Merlin locations."},"new_name":{"type":"string","minLength":1,"description":"Replacement identifier. Its lexical class (lowercase value vs uppercase constructor/module) must match the entity under the cursor."},"dry_run":{"type":"boolean","description":"When true, report the planned rename (files, per-file counts, old and new names) without writing. Defaults to false, which applies the rename."},"max_occurrences":{"type":"integer","minimum":1,"maximum":1000,"description":"Safety cap on the number of occurrences a single rename may rewrite. Exceeding it refuses. Defaults to 200."}},"required":["path","line","column","new_name"],"additionalProperties":false}
  
  ## ocaml_replace_expressions
  
  Rewrite workspace OCaml expressions by structure: find every expression
  matching an OCaml `pattern` and replace it using a `template`. The template is
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
  
  Input schema: {"type":"object","properties":{"pattern":{"type":"string","description":"OCaml expression pattern. __ matches any expression, __1/__2 are unification metavariables reused by the template, and match/record clauses match as sets."},"template":{"type":"string","description":"OCaml expression with the same __1/__2 holes as the pattern. Each hole is filled with the exact source text the metavariable matched."},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Workspace-relative or workspace-contained file or directory roots. Defaults to the workspace current directory."},"max_sites":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum rewritten sites across all files. If exceeded, nothing is written. Defaults to 200."},"dry_run":{"type":"boolean","description":"When true, validate and render but write nothing, returning per-site before/after and the diff. Defaults to false (the tool applies in one call)."}},"required":["pattern","template"],"additionalProperties":false}
  
  ## ocaml_dune_describe
  
  Describe the OCaml project from Dune metadata: libraries, executables,
  compilation units, dependencies, tests, and build context.
  
  Use it before broad OCaml changes — adding modules, changing library
  dependencies, reasoning about test targets — instead of inferring the
  project shape from directory listings. It runs `dune describe` once and
  normalizes the result; it does not start or depend on a Dune watch.
  
  Input schema: {"type":"object","properties":{},"additionalProperties":false}
  
  ## ocaml_dune_diagnostics
  
  Read the current OCaml compiler and Dune errors and warnings for the
  workspace, with source locations.
  
  Check diagnostics after edits and before claiming a change done — a
  clean diagnostic set is the OCaml verification baseline. The tool
  returns the latest set observed from the workspace's running Dune
  instance; it does not start Dune or block waiting for a rebuild. If it
  reports unavailable, no Dune instance is currently visible — fall back
  to building through the shell.
  
  Input schema: {"type":"object","properties":{},"additionalProperties":false}
  
  ## ocaml_docs
  
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
  
  Input schema: {"type":"object","properties":{"query":{"type":"string","description":"A workspace file path (has a / or ends in .ml/.mli), a findlib/local library name (lowercase, dotted), a capitalized module path, or a qualified identifier. The form is selected by the query's shape."},"scope":{"type":"string","enum":["workspace","deps","any"],"description":"Name-form resolution universe. workspace restricts to local libraries, deps to dependencies, any (default) resolves against both and reports an ambiguity when a name matches both. Ignored for path-form queries."},"package":{"type":"string","description":"findlib library hint that forces the containing library for a capitalized query whose root module does not match its library name."},"depth":{"type":"integer","minimum":0,"description":"Inline nested-module expansion depth. Defaults to 0 (nested module bodies collapse to a member count)."},"offset":{"type":"integer","minimum":1,"description":"1-based first preorder outline item to return. Defaults to 1."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum number of outline items to return. Defaults to 100."},"max_source_bytes":{"type":"integer","minimum":1,"maximum":8388608,"description":"Maximum accepted resolved source-file size in bytes. Defaults to 2097152."}},"required":["query"],"additionalProperties":false}
  
  ## ocaml_find_definitions
  
  Locate an OCaml identifier's definition, declaration, or type definition
  using Merlin semantics in the current Dune project context.
  
  Prefer this over textual search when you need where a name is actually
  defined — it resolves through opens, includes, aliases, and shadowing,
  where grepping guesses. Input positions use 1-based lines and 0-based
  byte columns, as rendered by read_file.
  
  Input schema: {"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative or workspace-contained absolute OCaml source file path."},"line":{"type":"integer","minimum":1,"description":"1-based source line of the lookup cursor."},"column":{"type":"integer","minimum":0,"description":"0-based byte column in the source line, matching OCaml/Merlin locations."},"identifier":{"type":"string","description":"Optional Merlin locate prefix. Omit this to locate the identifier under the cursor."},"kind":{"type":"string","enum":["definition","declaration","type-definition"],"description":"Lookup kind. Defaults to definition. type-definition cannot be used with identifier."}},"required":["path","line","column"],"additionalProperties":false}
  
  ## ocaml_find_references
  
  Find semantic references to the OCaml entity at a file position using
  Merlin occurrences. The query is identity-based, not a textual grep: it
  finds uses of that specific binding, not strings that happen to match.
  
  Prefer this over search_text when assessing a rename or a signature
  change's blast radius. Input is a workspace OCaml file path plus a
  1-based line and 0-based byte column. Project-wide scope depends on the
  Merlin/Dune occurrence index; stale occurrences are excluded by default.
  
  Input schema: {"type":"object","properties":{"path":{"type":"string","minLength":1,"description":"Workspace-relative or workspace-contained absolute OCaml source file path."},"line":{"type":"integer","minimum":1,"description":"1-based source line of the identifier cursor."},"column":{"type":"integer","minimum":0,"description":"0-based byte column in the source line, matching OCaml/Merlin locations."},"scope":{"type":"string","enum":["buffer","project","renaming"],"description":"Merlin occurrence scope. Defaults to project. buffer is current-file only; project and renaming depend on Merlin/Dune occurrence indexes."},"include_stale":{"type":"boolean","description":"Include stale occurrences reported by Merlin. Defaults to false so outdated index hits are skipped."},"offset":{"type":"integer","minimum":1,"description":"1-based index of the first reference to return within the fresh result set. Defaults to 1. Use the [next:] continuation to page through more references."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum returned references after stale filtering. Defaults to 200."}},"required":["path","line","column"],"additionalProperties":false}
  
  ## ocaml_search_expressions
  
  Search workspace OCaml sources for code shaped like an OCaml expression
  pattern. Matching is structural, not textual: it is invariant to
  formatting and line breaks, `__` matches any expression, `__1`/`__2`
  force structurally equal sub-expressions, pattern arguments may omit
  call arguments, `f ?arg:PRESENT` / `f ?arg:MISSING` constrain optional
  arguments, and match/try/function clauses and record fields match as
  order-independent sets. Example: `List.rev __ @ __` or
  `match __ with None -> __ | Some __1 -> Some __1`.
  
  Matching is syntactic — identifiers match as written (with path-suffix
  tolerance: `filter` matches `List.filter`), so it does not see through
  `open` or module aliases; use ocaml_find_references when binding
  identity matters. Sources are parsed directly, so it works on unbuilt
  code, but files with syntax errors cannot be searched and are reported
  as skipped. Type-constrained patterns like `(__ : t)` are not
  supported. For plain text or regex searches, and for non-OCaml files,
  use search_text.
  
  Input schema: {"type":"object","properties":{"pattern":{"type":"string","description":"OCaml expression pattern. __ matches any expression, __1/__2 are unification metavariables, f ?arg:PRESENT / f ?arg:MISSING constrain optional arguments, and match/record clauses match as sets."},"paths":{"type":"array","items":{"type":"string"},"minItems":1,"description":"Workspace-relative or workspace-contained absolute file or directory roots. Defaults to the workspace current directory."},"offset":{"type":"integer","minimum":1,"description":"1-based first finding to return. Defaults to 1."},"limit":{"type":"integer","minimum":1,"maximum":1000,"description":"Maximum number of findings to return. Defaults to 100."}},"required":["pattern"],"additionalProperties":false}
  
  ## ocaml_type_at
  
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
  
  Input schema: {"type":"object","properties":{"path":{"type":"string","minLength":1,"description":"Workspace-relative or workspace-contained absolute OCaml source file path."},"line":{"type":"integer","minimum":1,"description":"1-based source line of the cursor."},"column":{"type":"integer","minimum":0,"description":"0-based byte column in the source line, matching OCaml/Merlin locations and read_file."},"max_enclosings":{"type":"integer","minimum":1,"maximum":8,"description":"Number of enclosing type frames to return, innermost-first. Each frame past the first costs a full Merlin re-type, so the cap is deliberately low. Defaults to 1."},"verbosity":{"type":"integer","minimum":0,"maximum":3,"description":"Merlin alias/module-type expansion depth. Raise this to unfold an unhelpful type alias. Defaults to 0."},"documentation":{"type":"boolean","description":"Also fetch the entity's odoc comment via Merlin document. Defaults to false."}},"required":["path","line","column"],"additionalProperties":false}
  
  ## shell
  
  Run one non-interactive shell command in a workspace directory.
  
  Prefer the dedicated tools over shell equivalents: read_file over cat and
  ls, search_text over grep or rg, glob over find, and the edit tools over sed
  or heredocs. Reach for shell when the task is a
  real command: builds, tests, git, package managers, running the project's
  binaries.
  
  Usage:
  - Each call is independent: workdir defaults to the workspace root, and
    shell state does not persist between calls. Chain dependent steps with
    && in one call; put independent commands in parallel calls.
  - Quote paths that contain spaces. Keep commands non-interactive; anything
    that prompts for input will hang until the timeout.
  - Do not sleep, poll, or retry a failing command unchanged — diagnose the
    failure first.
  - The host selects the shell, sandbox, environment, and timeout and output
    bounds. If a command fails because of sandbox restrictions, retry that
    one command with escalate=true and the reason in description; escalation
    needs explicit user approval and is unavailable in read-only runs.
  
  Input schema: {"type":"object","properties":{"command":{"type":"string","description":"Non-empty shell command text."},"workdir":{"type":"string","description":"Workspace-relative or workspace-contained absolute directory. Defaults to the workspace root."},"timeout_ms":{"type":"integer","minimum":1,"description":"Optional command timeout in milliseconds, bounded by host configuration."},"description":{"type":"string","description":"Optional reviewer/UI metadata."},"escalate":{"type":"boolean","description":"Request to run this one command outside the sandbox. Use only after a command failed because of sandbox restrictions, with the reason in description. Requires explicit user approval and is unavailable in read-only runs."}},"required":["command"],"additionalProperties":false}
  
  ## skill
  
  Load a skill: named, reusable guidance for a specific kind of task.
  
  Match skills against the task at hand, not just the user's wording. "Add a
  parser to lib/" matches a module-design skill even though the user never
  said "design"; check the work you are about to do — writing an interface,
  documenting, testing, optimizing — against each skill's description.
  
  Load the skill before starting the work, not after. If several skills apply
  to one task, load each of them. When unsure whether a skill applies, load
  it: a load costs one tool call, while missed guidance costs quality. Load a
  skill at most once per task; if its content is already in context, follow
  it instead of loading it again. A loaded skill may point to another skill
  by name; load that one when its scope becomes relevant.
  
  Call with a skill name from the listing below — only names that appear
  there exist; never guess or invent one. Omit `resource` to load the skill
  guidance. A loaded skill may list resource files; read one by
  calling this tool again with the same name and the resource's relative path
  in the `resource` field.
  
  Skills are guidance, not policy: they never change which tools or
  permissions are available.
  
  Available skills:
  - ocaml-benchmarking: Guides setting up and maintaining benchmark suites for OCaml code. Use when adding benchmarks, setting up a bench suite, tracking performance regressions, wiring benchmarks into dune runtest, or proving that an optimization holds. Triggers on phrases like "add a benchmark", "set up benchmarks", "bench suite", "performance regression", "thumper", "baseline", or "did this get slower". For diagnosing and fixing slowness, load ocaml-perf.
  - ocaml-concurrency: Guides writing concurrent and parallel OCaml 5 code — choosing between Eio, Lwt, Miou, and Domainslib, using domains correctly, sharing state under the memory model, and structured concurrency with cancellation. Use when adding concurrency or parallelism, writing or reviewing code that uses domains, fibers, promises, Atomic, or Mutex, or when reasoning about races and deadlocks. Triggers on phrases like "make this concurrent", "parallelize this", "use domains", "Eio or Lwt", "data race", "run in parallel", "thread-safe", or "async".
  - ocaml-debug: Guides systematic debugging of OCaml code — reproducing failures, getting usable backtraces, inspecting values without polymorphic print, and the OCaml-specific toolbox (project toplevel, ocamldebug time travel, logs, sanitizers). Use when investigating a bug, crash, wrong result, hang, unexpected exception, or a failing test with an unclear cause. Triggers on phrases like "debug this", "why is this failing", "no backtrace", "stack overflow", "segfault", "it hangs", "wrong result", or "can't reproduce".
  - ocaml-doc: Writes and reviews OCaml API documentation, with `.mli` doc comments as the source of API truth and longer guides as Markdown under `doc/`. Use when documenting, improving, or auditing OCaml interfaces — module summaries, section structure, contracts, cross-references, errors, invariants, examples, odoc formatting — and whenever writing or editing doc comments in an `.mli`. Triggers on phrases like "document this module", "write the docs", "docstrings", "odoc", "API reference", "tutorial", "cookbook", or "Bunzli style".
  - ocaml-dune: Guides authoring dune build logic well - custom rules, actions, dependency specs, aliases, promotion, env stanzas, and build workflow etiquette. Use when writing or editing dune files beyond basic stanzas, adding a custom rule or alias, wiring generated code into the build, tuning flags per profile, or diagnosing a failing or flaky build. Triggers on phrases like "add a dune rule", "generate this file at build time", "attach it to runtest", "custom alias", "dune promote", "why doesn't dune rebuild this", "release profile flags", or "unbound module". For dune-project and opam metadata, load ocaml-project-setup; for writing tests, ocaml-testing; for C stubs, ocaml-ffi.
  - ocaml-ffi: Guides writing correct and performant OCaml-to-C FFI stubs without ctypes. Use when writing C bindings, wrapping a C library, writing or reviewing stubs and externals, or touching any C file that includes caml/ headers. Triggers on phrases like "C binding", "FFI", "external", "stub", "noalloc", "bigarray interop", "custom block", "caml_release_runtime", or "wrap this C library".
  - ocaml-library-design: Designs OCaml library architecture — how a family of modules composes around a narrow waist. Use when designing, reviewing, or restructuring a library's public surface, package layout, extension interface, or bridges to other libraries, and when an API keeps sprouting special-case functions. Triggers on phrases like "design this library", "library architecture", "review the API", "narrow the waist", "simplify the surface", "how should these modules fit together", or "extension interface". For the signature of a single module, load ocaml-module-design instead.
  - ocaml-module-design: Designs the signature of a single OCaml module — its core type, constructors, eliminators, errors, and invariants. Use when writing, reviewing, or reshaping an .mli, choosing a type representation, or doing API design for one module or a small family of related types. Triggers on phrases like "design this module", "what should the .mli look like", "review this signature", "what type should I use", "how should I expose this", or "API design". For how multiple modules fit together, load ocaml-library-design instead.
  - ocaml-perf: Guides measurement-driven performance optimization of OCaml code. Use when optimizing, profiling, speeding up, or reducing allocations in OCaml code, and when reviewing performance-sensitive code. Triggers on phrases like "make this faster", "too many allocations", "profile this", "optimize", "GC pressure", "hot loop", or "why is this slow". For setting up a benchmark suite, load ocaml-benchmarking.
  - ocaml-project-setup: Standards for OCaml project scaffolding and metadata files. Use when initializing a new OCaml library or executable project, preparing for an opam release, setting up CI, adding missing .mli/.ocamlformat files, or reviewing project structure. Triggers on phrases like "new OCaml project", "set up this project", "dune-project", "prepare for release", "add CI", or "project structure".
  - ocaml-release: Guides releasing OCaml packages to opam — choosing a version, changelog discipline, the dune-release tag/distrib/publish/submit workflow, and what opam-repository CI and review expect. Use when preparing or cutting a release, publishing a package to opam, bumping a version, writing release notes, or fixing a failing opam-repository PR. Triggers on phrases like "release this package", "publish to opam", "dune-release", "bump the version", "cut a release", "update the changelog", or "the opam PR failed". For scaffolding a project before its first release, load ocaml-project-setup.
  - ocaml-testing: Guides writing effective tests for OCaml code — choosing the right test level, using windtrap for unit, property, snapshot, and expect tests, and dune cram tests for executables. Use when writing tests, adding a test suite to a project, reviewing existing tests, or setting up cram tests. Triggers on phrases like "write tests for this", "add a test suite", "test this function", "set up cram tests", "property test this", "snapshot test", "review these tests", or "check coverage".
  - ocaml-tidy: Tidies OCaml .ml implementation code for clarity, density, locality, and maintainability without changing behavior. Use when tidying, cleaning up, simplifying, or readability-refactoring OCaml implementation files or snippets while preserving semantics, and when reviewing .ml code for clarity. Triggers on phrases like "tidy this", "clean up this file", "simplify this code", "refactor for readability", "make this more idiomatic", or "review this .ml".
  
  Input schema: {"type":"object","properties":{"name":{"type":"string","description":"Name of the skill to load, from the available skills listing."},"resource":{"type":"string","minLength":1,"description":"Optional path of a resource file to read, relative to the skill directory. Use only resource names listed by the skill guidance. Omit this field, or pass /, to load the skill guidance."}},"required":["name"],"additionalProperties":false}
  
  ## ask_user
  
  Ask the user one concise question when execution is genuinely blocked on
  their input: a requirement ambiguity the repository cannot resolve, a
  destructive or hard-to-reverse action needing confirmation, or a missing
  secret or credential.
  
  Make the question concrete and answerable in a sentence — state the
  options you see and which you would pick. Do not ask for permission to
  proceed with the obvious next step, and do not use this to approve a
  plan: in plan mode, propose_plan is the approval mechanism.
  
  Input schema: {"type":"object","properties":{"header":{"type":"string"},"question":{"type":"string"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"],"additionalProperties":false}},"multi":{"type":"boolean"}},"required":["question"],"additionalProperties":false}
  
  ## todo_write
  
  Replace the visible todo list for the current session. Use it to track
  implementation progress on work with three or more distinct steps, or
  when the user gives several tasks at once. Skip it for a single
  straightforward task — just do the task. It does not approve plans.
  
  Usage:
  - Omit `owner` or use `owner: "main"` for the main thread. Positions are
    zero-based and contiguous per owner.
  - Keep at most one todo `in_progress` per owner: mark a step in_progress
    when you start it and completed as soon as it is done — never batch
    completions after the fact.
  - Never mark a step completed while its checks fail or its work is
    partial; keep it in_progress and add a todo describing the blocker.
  
  Input schema: {"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string","minLength":1,"description":"Stable non-empty todo id."},"owner":{"type":"string","minLength":1,"description":"Todo owner. Defaults to \"main\" for the main assistant thread."},"content":{"type":"string","minLength":1,"description":"Actionable todo text."},"status":{"type":"string","enum":["pending","in_progress","completed","cancelled"],"description":"Todo lifecycle. Use at most one in_progress todo per owner."},"priority":{"type":"string","enum":["high","medium","low"],"description":"Todo priority."},"position":{"type":"integer","minimum":0,"description":"Zero-based order within the owner list. Positions must be contiguous: 0, 1, 2, ... ."}},"required":["id","content","status","priority","position"],"additionalProperties":false}}},"required":["todos"],"additionalProperties":false}
  
  ## update_goal
  
  Report the session goal's final state. Call it only when the goal is
  complete or truly blocked — never to narrate progress, pause, or
  renegotiate the objective; those are user actions.
  
  - `status: "complete"` claims the full objective is achieved. Treat
    completion as unproven until you have verified every explicit
    requirement against authoritative current state — files, command
    output, test results — not intent, memory of earlier work, or a
    plausible final answer. If any requirement is missing, incomplete, or
    unverified, keep working instead of calling this.
  - `status: "blocked"` means you are at a real impasse that only user
    input or an external change can resolve, and the same blocking
    condition has repeated for at least three consecutive goal turns.
    Never use it because the work is hard, slow, uncertain, or would
    benefit from clarification.
  - `summary`: one or two sentences — what was delivered, or the exact
    blocker and what would unblock it.
  
  Do not mark a goal complete because the budget is nearly exhausted or
  because you are stopping work. When a budgeted goal completes, report
  the final token usage from the tool result to the user.
  
  Input schema: {"type":"object","properties":{"status":{"type":"string","enum":["complete","blocked"],"description":"The goal's final state: complete only when every requirement is verified against current evidence; blocked only at a real, repeated impasse."},"summary":{"type":"string","minLength":1,"description":"One or two sentences: what was delivered, or the exact blocker and what would unblock it."}},"required":["status"],"additionalProperties":false}
  
  ## spawn_subagent
  
  Delegate bounded work to a child session with a fresh context. The host
  decides whether the requested role is allowed.
  
  The child runs detached: this call returns immediately with the child's
  session id, and you keep working while it runs. Its result arrives as a
  notice; call wait_subagents with the session id when your next step
  needs the result before you can continue. Steer a running child, answer
  its question, or resume a finished one for follow-up work with
  message_subagent — a resumed child keeps its context, so prefer that
  over respawning and re-briefing. Cancel a run you no longer need with
  cancel_subagent.
  
  Roles:
  - explore — read-only search and reading; returns findings with paths.
    Use for open-ended investigation across many files where you need the
    conclusion, not the file contents, in your context.
  - review — read-only inspection of an assigned surface; returns
    severity-ordered findings.
  - verify — runs checks through the shell (build, tests, probes) and
    returns evidence with a PASS, FAIL, or PARTIAL verdict.
  
  Do not spawn for needle queries: a known file → read_file; a specific
  symbol or string → search_text; a couple of known files → read them
  directly.
  
  The subagent has not seen this conversation. Brief it like a colleague
  who just walked in: the goal and why, the relevant paths, what you
  already ruled out, and exactly what its final message must contain —
  including how thorough to be (a quick look at one area vs an exhaustive
  sweep across naming conventions and locations). Do not delegate
  synthesis you have not done ("figure out what matters and fix it");
  delegate questions or checks you can state precisely. An explore child
  locates and summarizes; it does not judge or audit — keep verdicts for
  review and verify.
  
  Independent delegations go in one response, in parallel; wait for them
  in one wait_subagents call. Do not redo the delegated work yourself
  while waiting. The subagent's output is not shown to the user — relay
  what matters in your own message. Do not end your turn while a spawned
  result you need is still pending.
  
  Input schema: {"type":"object","properties":{"role":{"type":"string","enum":["explore","review","verify"]},"task":{"type":"string"},"scope":{"type":"array","items":{"type":"string"}},"expected_output":{"type":"string"}},"required":["role","task"],"additionalProperties":false}
  
  ## wait_subagents
  
  Block until the named subagent runs settle and return their results.
  
  Spawned subagents run detached: spawn_subagent returns immediately with
  a run id, you keep working, and results arrive as notices. Call this
  tool only when your next step needs a result you have not received yet
  — pass every run id you are blocked on in one call, not one call per
  run.
  
  A blocked or failed run returns its blocker or failure message; a
  cancelled run reports that it was cancelled. Waiting on a run that
  already settled returns its recorded result again.
  
  Input schema: {"type":"object","properties":{"runs":{"type":"array","items":{"type":"string"}}},"required":["runs"],"additionalProperties":false}
  
  ## cancel_subagent
  
  Interrupt a running subagent.
  
  Use this when a run's task is no longer needed — the plan changed, its
  question was answered elsewhere, or a sibling already produced the
  result. Cancellation is a neutral outcome, not a failure: the run
  settles as cancelled and any partial work in its session remains
  inspectable.
  
  Cancelling a run that already settled is an error and changes nothing.
  
  Input schema: {"type":"object","properties":{"run":{"type":"string"}},"required":["run"],"additionalProperties":false}
  
  ## message_subagent
  
  Send a message to a subagent run: steer it, answer its question, or
  resume it for follow-up work.
  
  Delivery is immediate from your side and never blocks. A running
  subagent sees the message before its next step. A subagent that asked
  you something via message_parent resumes with your message as the
  answer. A settled subagent resumes with a new turn carrying your
  message — its context is intact, so message it for follow-ups instead
  of spawning a fresh child and re-briefing from zero.
  
  If a running subagent finishes without acting on a message you sent,
  message it again to resume it.
  
  Input schema: {"type":"object","properties":{"run":{"type":"string"},"message":{"type":"string"}},"required":["run","message"],"additionalProperties":false}

Every other model receives the string-replace family — write_file plus edit_file
— and no apply_patch. The same catalog otherwise; assert the family difference
and the honest header rather than duplicating the whole dump.

  $ spice debug tools --model anthropic/claude-opus-4-8 | grep -E '^Editor family|^## (write_file|edit_file|apply_patch)'
  Editor family: string-replace (capability)
  ## write_file
  ## edit_file

Plan and review modes restrict the catalog to read-only workspace tools and
mode-specific host tools.

  $ spice debug tools --mode plan | grep '^##'
  ## read_file
  ## search_text
  ## glob
  ## skill
  ## ask_user
  ## propose_plan
  ## spawn_subagent
  ## wait_subagents
  ## cancel_subagent
  ## message_subagent

  $ spice debug tools --mode review | grep '^##'
  ## read_file
  ## search_text
  ## glob
  ## skill
  ## ask_user
  ## spawn_subagent
  ## wait_subagents
  ## cancel_subagent
  ## message_subagent

The JSON view returns the same declarations as request facts, with the resolved
editor family as a fact of the snapshot.

  $ spice debug tools --model openai/gpt-5.5 --json | grep -o '"editor_family":"apply-patch"'
  "editor_family":"apply-patch"

  $ spice debug tools --json | grep -c '"type":"debug_tools"'
  1

The model-conditioning report prints each decision with its provenance, using
the same resolvers a run uses.

  $ spice debug model --model openai/gpt-5.5
  Model: gpt-5.5
  editor: apply-patch (capability)
  reasoning: medium (declared default)
  compaction: 1030000 (auto limit 1030000 from the declared context window)

  $ spice debug model --model anthropic/claude-opus-4-8 --json | grep -o '"editor":{"value":"string-replace","reason":"capability"}'
  "editor":{"value":"string-replace","reason":"capability"}
