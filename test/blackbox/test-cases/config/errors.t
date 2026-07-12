Spice config reports usage errors for invalid keys and values.

Unknown keys are rejected before config files are edited.

  $ spice config get nope
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: unknown config key: nope Hint: supported keys: model,
         small_model, reasoning, providers.<provider>.base_url, tui.thinking,
         run.max_steps, run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

  $ spice config set nope value
  Usage: spice config set [--help] [--project] [--project-local] [--user]
         [OPTION]… KEY VALUE
  spice: KEY argument: unknown config key: nope Hint: supported keys: model,
         small_model, reasoning, providers.<provider>.base_url, tui.thinking,
         run.max_steps, run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

  $ spice config unset nope
  Usage: spice config unset [--help] [--project] [--project-local] [--user]
         [OPTION]… KEY
  spice: KEY argument: unknown config key: nope Hint: supported keys: model,
         small_model, reasoning, providers.<provider>.base_url, tui.thinking,
         run.max_steps, run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

Misspelled keys get a spelling hint.

  $ spice config get modle
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: unknown config key: modle Hint: did you mean model?
         Hint: supported keys: model, small_model, reasoning,
         providers.<provider>.base_url, tui.thinking, run.max_steps,
         run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

  $ spice config get instructions.glbal
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: unknown config key: instructions.glbal Hint: did you
         mean instructions.global? Hint: supported keys: model, small_model,
         reasoning, providers.<provider>.base_url, tui.thinking, run.max_steps,
         run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

Misspelled provider keys get the key shape.

  $ spice config get providers.openai.baseurl
  Usage: spice config get [--help] [OPTION]… KEY
  spice: KEY argument: unknown config key: providers.openai.baseurl Hint:
         provider keys are spelled providers.<provider>.base_url Hint:
         supported keys: model, small_model, reasoning,
         providers.<provider>.base_url, tui.thinking, run.max_steps,
         run.subagent_max_concurrent, run.subagent_max_depth,
         run.subagent_wake, run.subagent_max_exchanges, permission.mode,
         permission.unattended, sandbox.mode, sandbox.require, sandbox.read,
         sandbox.readable_roots, sandbox.writable_roots, sandbox.network,
         shell, compaction.auto, notices.fswatch, notices.cr_comments,
         notices.dune_diagnostics, notices.dune_build, workspace.tooling,
         instructions.global, instructions.project, instructions.claude_md,
         instructions.project_max_bytes, skills.enabled, skills.builtin,
         skills.project, skills.compat, skills.disabled, skills.paths,
         skills.catalog_max_bytes, tools.anchored_edits, tools.editor,
         ocaml.merlin_program, web.enabled, web.allow_private_network,
         web.search_backend, web.fetch_max_bytes, web.output_max_chars,
         web.timeout_ms, web.max_timeout_ms
  [124]

Invalid provider ids are rejected.

  $ spice config set providers.OpenAI.base_url https://example.invalid
  Usage: spice config set [--help] [--project] [--project-local] [--user]
         [OPTION]… KEY VALUE
  spice: KEY argument: invalid provider id "OpenAI": id must start with a
         lowercase ASCII letter
  [124]

Invalid typed values are rejected as usage errors.

  $ spice config set permission.mode unknown
  spice: unknown permission mode: unknown
  Hint: expected one of: default, accept-edits, plan, bypass
  [2]

  $ spice config set permission.mode pln
  spice: unknown permission mode: pln
  Hint: expected one of: default, accept-edits, plan, bypass
  Hint: did you mean plan?
  [2]

  $ spice config set reasoning hyper
  spice: unknown reasoning effort: hyper
  Hint: expected one of: none, minimal, low, medium, high, xhigh, max
  [2]

  $ spice config set run.max_steps 0
  spice: run.max_steps must be positive
  [2]

  $ spice config set run.max_steps -- -1
  spice: run.max_steps must be positive
  [2]

  $ spice config set run.max_steps 1.5
  spice: run.max_steps must be an integer
  [2]

  $ spice config set run.max_steps abc
  spice: run.max_steps must be an integer
  [2]

  $ spice config set run.max_steps 9007199254740992
  spice: run.max_steps must be at most 9007199254740991
  [2]

Boolean instruction keys accept exactly true or false.

  $ spice config set instructions.global yes
  spice: instructions.global must be true or false
  [2]

  $ spice config set instructions.claude_md TRUE
  spice: instructions.claude_md must be true or false
  [2]

A zero budget is invalid: disabling project instructions is spelled through
instructions.project, not through the budget.

  $ spice config set instructions.project_max_bytes 0
  spice: instructions.project_max_bytes must be positive
  [2]

  $ spice config set instructions.project_max_bytes abc
  spice: instructions.project_max_bytes must be an integer
  [2]

  $ spice config set model ''
  spice: invalid model "": model selector must not be empty
  [2]

Model writes share one validation policy with `spice models select`: a
selection rejected there cannot be written here.

  $ spice config set model openai/gpt-55
  spice: unknown model "gpt-55" for provider "openai"
  Hint: did you mean gpt-5.5, gpt-5.4 or gpt-5.2?
  [2]

  $ spice config set model openai/gpt-5-chat-latest
  spice: unavailable model "openai/gpt-5-chat-latest": OpenAI Responses does not support this chat alias
  Hint: run `spice models --all` to inspect model status
  [2]

Rejected edits do not create a config file.

  $ test -e "$XDG_CONFIG_HOME/spice/config.json" || echo "no config"
  no config

Conflicting target flags are usage errors.

  $ spice config set --user --project model openai/gpt-5.5
  spice: choose only one config target
  [124]
