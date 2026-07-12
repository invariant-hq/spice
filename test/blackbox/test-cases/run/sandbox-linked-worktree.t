Project-scoped reads discover linked-worktree Git metadata without executing
Git during sandbox resolution. The external metadata is readable but never a
writable root.

  $ export SPICE_SANDBOX_MODE=workspace-write
  $ export _SPICE_TEST_SANDBOX_UNAVAILABLE=1
  $ unset CAML_LD_LIBRARY_PATH OCAMLLIB OCAMLPATH OCAML_TOPLEVEL_PATH OPAM_SWITCH_PREFIX DUNE_OCAML_STDLIB
  $ ROOT="$PWD"
  $ spice config set sandbox.read project
  $ mkdir main
  $ git -C main init -q
  $ git -C main config user.name "Spice Test"
  $ git -C main config user.email "spice@example.invalid"
  $ touch main/file
  $ git -C main add file
  $ git -C main commit -qm initial
  $ git -C main worktree add -qb linked ../linked

  $ spice sandbox explain --cwd "$PWD/linked" | grep 'origin=git-worktree' | sed "s,$ROOT,TEST_ROOT,g"
  readable=TEST_ROOT/main/.git origin=git-worktree
  $ spice sandbox explain --cwd "$PWD/linked" | grep '^writable='
  writable=.
  $ spice sandbox explain --cwd "$PWD/linked" | grep '^protected='
  protected=./.git
