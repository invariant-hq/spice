# Spice evaluation suite

This directory is the whole evaluation suite: the corpus of OCaml tasks, the
agent adapters, the grading checks, and the `spice-eval` runner.
Everything lives under `eval/`; run output goes to the git-ignored `_evals/`
directory at the repository root.

## Layout

- `lib/` — the pure `spice_eval` library: usage, checks, tasks, result rows,
  scoring, reports. Unit-tested in `test/`.
- `bin/` — the `spice-eval` executable: workspace materialization,
  subprocess adapters, the judge, artifact IO, and corpus suite selection.
- `fixtures/` — task fixture projects, copied into fresh run workspaces.
  Declared `data_only_dirs`: some are deliberately broken (failing tests,
  missing docs), so dune must not build them in place.
- `TASK_RUBRIC.md` — admission criteria for adding benchmark tasks.

## Quick start

```sh
dune build
dune exec spice-eval -- list --checks
# Live run: real spice against the configured provider.
dune exec spice-eval -- run --suite smoke --model openai/gpt-5.5 --runs 1
dune exec spice-eval -- report _evals/results/<dir>
dune exec spice-eval -- compare <baseline-rows> _evals/results/<dir>
```

`run` drives the locally built spice binary (`_build/default/bin/main.exe`)
through `spice run --json --permission-mode bypass` and reads the metrics
member of the final JSONL event. Auth and model configuration come from your
normal spice environment.

## Suites

`--suite` selects a benchmark tier:

- `smoke` — tiny deterministic tasks for harness and catastrophic-regression
  checks.
- `core` — common user workflows such as bugfixes, docs, tests, and refactors.
- `long` — larger multi-step engineering tasks. This suite is intentionally
  empty until tasks pass `TASK_RUBRIC.md`.
- `robustness` — adversarial and UX-sensitive tasks. This suite is
  intentionally empty until tasks pass `TASK_RUBRIC.md`.
- `all` — the union of every tier.

Each task records `tier`, `category`, `size`, and `oracle` metadata for report
slicing. See `TASK_RUBRIC.md` before adding tasks.

## Agents

`--agent` selects the adapter:

- `spice` (default) — `spice run --json`; reports usage, turns, tool calls,
  tool failures from session metrics.
- `claude` — `claude -p --output-format json`; reports usage and turns.
- `codex` — `codex exec --json`; usage summed from `turn.completed` events.
- `noop` — does nothing; exercises materialization and grading.
- `cmd:COMMAND` — runs COMMAND in the workspace with the task prompt in
  `SPICE_EVAL_PROMPT`; deterministic harness validation with zero tokens:

```sh
dune exec spice-eval -- run --suite smoke \
  --agent 'cmd:printf "let answer = 42\n" > lib/spice_eval_smoke.ml'
```

Fields an adapter cannot recover from its agent are omitted from the row,
never zeroed.

## Judging quality checks

Quality criteria are judged only when a judge model is given:

```sh
dune exec spice-eval -- run --task words-rev-bugfix \
  --model openai/gpt-5.5 --judge-model openai/gpt-5.5 --judge-samples 3
```

Each sample is one `spice run` call (the judge sees the task prompt, the
diff, and the criterion — never the agent transcript) and must answer with a
JSON `{"score", "rationale"}` object. Samples are recorded on the finding;
the judge model is part of the row identity, and rows with different judge
identities should not be averaged together. Without `--judge-model`, quality
checks record `skipped` and are excluded from the base score. Note that
judge calls create ordinary spice sessions in your session store.

## Costs

Dollar figures are computed at report time from the built-in provider
catalog (`Spice_provider.Model.pricing`), never stored in rows. Pass `--model
provider/model` on `run` so rows carry a resolvable model id; unknown models
report no cost. `report` prints per-task token and cost means over
successful runs plus headline cost-of-success and wasted (failed-run) cost.

## Results, artifacts, baselines

Each run writes `_evals/results/<timestamp>/` (override with `--output`):

- `rows.jsonl` — one schema-versioned result row per task × run index:
  series identity (task, agent + version, model, judge model, Spice version),
  run index, status, metrics, and one finding per check.
- `<task>-<n>/` — per-run artifacts: the workspace as the agent left it,
  the agent log, `git-diff.stdout`, per-command check output, judge
  prompts/replies.

A baseline is a blessed `rows.jsonl`. To keep one, copy it under
`eval/baselines/<name>.jsonl` and commit it deliberately; `compare` exits
non-zero when the aggregate or any per-task mean score regresses past
tolerance.

## Caveats

- Comparative claims across providers should lead with cost, not raw token
  counts; tokenizers differ.
- The `claude` and `codex` adapters track those CLIs' current headless
  flags; a flag change shows up as `agent_error` rows, not silent zeros.
- One run executes the agent and the checks with a default 600 s wall-clock
  timeout per process tree; task `~timeout_s` overrides it.
