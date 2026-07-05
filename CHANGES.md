# 0.1.0 (unreleased)

First public release of spice, the OCaml coding agent.

- Interactive TUI (`spice`) and headless mode (`spice run`) for planning,
  editing, and reviewing OCaml projects.
- Anthropic, OpenAI, and Google providers via OAuth or API key, plus local
  models through llama.cpp.
- OCaml-aware tooling: Dune RPC diagnostics, build integration, and
  type-directed context.
- Permission presets, sandboxed execution, workspace trust, and
  turn-by-turn session diff/revert.
- Prebuilt binaries for macOS (arm64, x64) and Linux (static musl x64,
  arm64), installable via `scripts/install.sh` or Homebrew.
