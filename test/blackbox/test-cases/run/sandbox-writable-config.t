Workspace-write gains durable, config-scoped writable roots and a network
knob, plus a curated dune-cache preset, so the default posture can build dune
projects without per-command escalation. `spice sandbox explain` renders the
resolved posture, so these are asserted without spawning a sandboxed command.
The backend seam pins enforcement off deterministically on every platform.

  $ export SPICE_SANDBOX_MODE=workspace-write
  $ export _SPICE_TEST_SANDBOX_UNAVAILABLE=1

A configured absolute writable root joins the writable set.

  $ spice config set sandbox.writable_roots '["/opt/spice-cache"]'
  $ spice sandbox explain --cwd "$PWD" | grep -o '/opt/spice-cache'
  /opt/spice-cache

A tilde-prefixed root expands against $HOME (here inside the workspace, so it
renders workspace-relative).

  $ spice config set sandbox.writable_roots '["~/build-cache"]'
  $ spice sandbox explain --cwd "$PWD" | grep -o 'home/build-cache'
  home/build-cache

The network knob flips the posture; it defaults to restricted.

  $ spice sandbox explain --cwd "$PWD" | grep '^network='
  network=restricted
  $ spice config set sandbox.network enabled
  $ spice sandbox explain --cwd "$PWD" | grep '^network='
  network=enabled

The dune-cache preset adds dune's cache directory to the writable set only
when the workspace is a dune project. Absent a dune-project, it is not added.

  $ export DUNE_CACHE_ROOT=/opt/dune-cache-xyz
  $ if spice sandbox explain --cwd "$PWD" | grep -q '/opt/dune-cache-xyz'; then echo present; else echo absent; fi
  absent

Adding a dune-project makes the workspace a dune project; the cache becomes
writable automatically, with no per-project config.

  $ touch dune-project
  $ spice sandbox explain --cwd "$PWD" | grep -o '/opt/dune-cache-xyz'
  /opt/dune-cache-xyz

The dune cache is never a project checkout, so protected-meta names are not
manufactured under it: the protected set stays the version-control and Spice
metadata dirs, never the cache root.

  $ if spice sandbox explain --cwd "$PWD" | grep '^protected=' | grep -q 'dune-cache'; then echo present; else echo absent; fi
  absent

The preset is overridable: sandbox.toolchain_caches=false drops it.

  $ spice config set sandbox.toolchain_caches false
  $ if spice sandbox explain --cwd "$PWD" | grep -q '/opt/dune-cache-xyz'; then echo present; else echo absent; fi
  absent
