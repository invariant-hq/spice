Project-local config updates maintain [.spice/.gitignore].

  $ git init -q

Initialization creates a gitignore entry.

  $ spice config init --project-local
  $ cat .spice/.gitignore
  config.local.json

Shared project initialization establishes the same local-config protection.

  $ mv .spice .spice-local-init
  $ spice config init --project
  $ cat .spice/.gitignore
  config.local.json

Running initialization again does not duplicate the entry.

  $ spice config init --project-local
  $ cat .spice/.gitignore
  config.local.json

Existing content is preserved.

  $ printf 'cache\n' > .spice/.gitignore
  $ spice config init --project-local
  $ cat .spice/.gitignore
  cache
  config.local.json

A missing trailing newline is handled cleanly.

  $ printf 'cache' > .spice/.gitignore
  $ spice config init --project-local
  $ cat .spice/.gitignore
  cache
  config.local.json

An existing entry is not duplicated when surrounded by other entries.

  $ printf 'cache\nconfig.local.json\nlogs\n' > .spice/.gitignore
  $ spice config init --project-local
  $ cat .spice/.gitignore
  cache
  config.local.json
  logs
