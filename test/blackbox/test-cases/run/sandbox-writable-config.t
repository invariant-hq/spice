Confined runs gain durable read and write root configuration plus a network
knob. `spice sandbox explain` renders the resolved posture, so these are
asserted without spawning a sandboxed command. The backend seam pins
enforcement off deterministically on every platform.

  $ export SPICE_SANDBOX_MODE=workspace-write
  $ export _SPICE_TEST_SANDBOX_UNAVAILABLE=1
  $ unset CAML_LD_LIBRARY_PATH OCAMLLIB OCAMLPATH OCAML_TOPLEVEL_PATH OPAM_SWITCH_PREFIX DUNE_OCAML_STDLIB

A configured absolute writable root joins the writable set.

  $ mkdir -p "$PWD/spice-cache"
  $ spice config set sandbox.writable_roots "[\"$PWD/spice-cache\"]"
  $ spice config get sandbox.writable_roots | grep -o 'spice-cache'
  spice-cache

A relative root is rejected and does not replace the previous valid value.

  $ spice config set sandbox.writable_roots '["relative-cache"]'
  spice: sandbox.writable_roots[0] must be absolute, "~", or start with "~/"
  [2]
  $ spice config get sandbox.writable_roots | grep -o 'spice-cache'
  spice-cache

A tilde-prefixed root expands against $HOME (here inside the workspace, so it
renders workspace-relative).

  $ mkdir -p "$HOME/build-cache"
  $ spice config set sandbox.writable_roots '["~/build-cache"]'
  $ spice config get sandbox.writable_roots
  ["~/build-cache"]

Read scope defaults to all-host access. Project scope and its additional roots
are independent, typed settings.

  $ spice config get sandbox.read
  all
  $ spice config set sandbox.read project
  $ spice config get sandbox.read
  project
  $ spice config set sandbox.read workspace 2>&1 | head -2
  spice: unknown sandbox read scope: workspace
  Hint: expected one of: project, all
  [2]
  $ spice config get sandbox.read
  project
  $ mkdir -p "$HOME/reference-source"
  $ spice config set sandbox.readable_roots '["~/reference-source"]'
  $ spice config get sandbox.readable_roots
  ["~/reference-source"]

The effective project posture explains every root with its admission reason.

  $ REFERENCE_ROOT="$PWD-reference-source"
  $ mkdir -p "$REFERENCE_ROOT"
  $ spice config set sandbox.readable_roots "[\"$REFERENCE_ROOT\"]"
  $ spice sandbox explain --cwd "$PWD" | grep '^reads='
  reads=project + system/runtime + toolchain
  $ spice sandbox explain --cwd "$PWD" | grep 'reference-source origin=user-configured' | sed "s,$PWD,WORKSPACE,g"
  readable=WORKSPACE-reference-source origin=user-configured
  $ spice config set sandbox.readable_roots '["~/reference-source"]'

Readable roots use the same path-spelling validation as writable roots.

  $ spice config set sandbox.readable_roots '["reference-source"]'
  spice: sandbox.readable_roots[0] must be absolute, "~", or start with "~/"
  [2]
  $ spice config get sandbox.readable_roots
  ["~/reference-source"]

Broad and missing roots fail closed at resolution instead of widening reads.

  $ spice config set sandbox.readable_roots '["/"]'
  $ spice sandbox explain --cwd "$PWD" 2>&1 | grep 'too broad'
  spice: sandbox.readable_roots root / is too broad; choose sandbox.read=all explicitly
  [1]
  $ spice config set sandbox.readable_roots '["~/does-not-exist"]'
  $ spice sandbox explain --cwd "$PWD" 2>&1 | grep 'invalid sandbox.readable_roots'
  spice: invalid sandbox.readable_roots[0] root "~/does-not-exist": No such file or directory
  [1]
  $ spice config set sandbox.readable_roots '["~/reference-source"]'

The removed cache toggle is not a compatibility alias for the new read policy.

  $ spice config get sandbox.toolchain_caches >old-key.out 2>&1
  [124]
  $ grep -o 'unknown config key: sandbox.toolchain_caches' old-key.out
  unknown config key: sandbox.toolchain_caches

Return to the default read scope before testing independent network behavior.

  $ spice config unset sandbox.readable_roots
  $ spice config set sandbox.read all

An extra readable root cannot imply confinement while the selected scope is
all-host.

  $ spice config set sandbox.readable_roots '["~/reference-source"]'
  $ spice sandbox explain --cwd "$PWD" 2>&1 | grep 'redundant'
  spice: sandbox.readable_roots is redundant when sandbox.read=all; remove it
  [1]
  $ spice config unset sandbox.readable_roots

The network knob flips the posture; it defaults to restricted.

  $ spice sandbox explain --cwd "$PWD" | grep '^network='
  network=restricted
  $ spice config set sandbox.network enabled
  $ spice sandbox explain --cwd "$PWD" | grep '^network='
  network=enabled
