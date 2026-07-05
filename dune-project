(lang dune 3.22)

(name spice)

(generate_opam_files)

; Keep dependency declarations honest: each stanza must name the libraries it
; uses instead of compiling through transitive dependencies.
(implicit_transitive_deps false)

(source
 (github invariant-hq/spice))

(homepage "https://github.com/invariant-hq/spice")

(documentation "https://github.com/invariant-hq/spice#readme")

(bug_reports "https://github.com/invariant-hq/spice/issues")

(authors "Thibaut Mattio <thibaut.mattio@gmail.com>")

(maintainers "Thibaut Mattio <thibaut.mattio@gmail.com>")

(maintenance_intent "(latest)")

(license ISC)

; These packages are developed together in the Mosaic repository. Pin them as a
; group so the TUI stack resolves from one compatible source revision.
(pin
 (url "git+https://github.com/invariant-hq/mosaic.git")
 (package
  (name tree-sitter)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic.git")
 (package
  (name matrix)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic.git")
 (package
  (name matrix-eio)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic.git")
 (package
  (name toffee)))

(pin
 (url "git+https://github.com/invariant-hq/mosaic.git")
 (package
  (name mosaic)))

(package
 (name spice)
 (synopsis "The OCaml coding agent")
 (description
  "Spice is a coding agent specialized for OCaml development. It uses OCaml's type system, build tools, package ecosystem, and editor diagnostics as first-class context so agents can make changes that are faster to produce, easier to review, and less likely to break than generic coding-agent output.\n\nSpice is built for safer, more productive agentic development in real OCaml codebases.")
 (depends
  (ocaml
   (>= 5.5.0))
  ; JSON/codecs and byte streams.
  (jsont
   (>= 0.2.0))
  (bytesrw
   (>= 0.3.0))
  ; Command-line surface and shared runtime plumbing.
  (cmdliner
   (>= 2.0.0))
  ; Diagnostics logging: libraries declare sources, the binary owns the
  ; reporter and level policy.
  (logs
   (>= 0.10.0))
  mtime
  ; OCaml-aware tools talk to Dune through RPC and csexp.
  csexp
  dune-build-info
  dune-rpc
  eio
  eio_main
  xdg
  ; HTTP/TLS client stack used by hosted LLM providers and web tools.
  ca-certs
  cohttp
  cohttp-eio
  cstruct
  domain-name
  mirage-crypto-rng
  tls
  tls-eio
  uri
  ; Skills use markdown documents with YAML frontmatter.
  yaml
  ; Terminal UI stack from the Mosaic repository pins above.
  mosaic
  matrix
  matrix-eio
  ; Local DeepSeek/DSML model runtime.
  deepseek
  ; Expect-style tests.
  (windtrap
   (and
    :with-test
    (>= 0.1.0)))
  (ppx_windtrap
   (and
    :with-test
    (>= 0.1.0))))
 (tags
  (ai cli coding-agent developer-tools ocaml org:invariant-hq)))
