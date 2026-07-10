# Spice evaluation suite

This directory is the whole evaluation suite: the corpus of OCaml tasks, the
agent adapters, the grading checks, and the `spice-eval` runner.
Everything lives under `eval/`; run output goes to the git-ignored `_evals/`
directory at the repository root.

## Layout

- `lib/` — the pure `spice_eval` library: usage, checks, tasks, result rows,
  scoring, reports, and marker scanning for subject blindness. Unit-tested in
  `test/`.
- `trace/` — the pure `spice_eval_trace` library: it decodes a captured
  session document into `Trace.t` (ordered, usage-attributed), then derives
  `Trace_metrics.t` numbers. It depends on `spice.session`/`spice.llm`, not on
  `spice_eval`, so the core stays agent-agnostic. Unit-tested in `test/`.
- `bin/` — the `spice-eval` executable: workspace materialization,
  subprocess adapters, the judge, artifact IO, corpus suite selection, and
  the `analyze` trace pass.
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
dune exec spice-eval -- analyze _evals/results/<dir>
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
- `screen` — a small, cheap subset of `core` spanning categories; the research
  lab's inner-loop suite.
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
  --agent 'cmd:printf "let answer = 42\n" > lib/basics.ml'
```

Fields an adapter cannot recover from its agent are omitted from the row,
never zeroed.

## Subject isolation and blindness

The agent must not be able to tell it is being evaluated, and must not inherit
the developer's personal spice configuration. The `spice` adapter therefore
constructs the subject environment rather than passing the developer's through:
every `SPICE_*` variable is dropped, and the subject gets a fresh per-run
`SPICE_DATA_HOME` and a seeded `SPICE_CONFIG_HOME` holding only credentials and
an empty `config.json` — the subject runs on pure spice defaults (no global
`AGENTS.md`, no personal model or editor overrides). `SPICE_AUTO_TITLE=0`
avoids an unmetered post-turn titling request. Provider API keys pass through.

Each run materializes its workspace under a marker-free temporary root (never
under `_evals/`), commits a neutral git baseline (`Initial commit`, plausible
author), and — between setup and agent start — runs a marker lint over
everything the harness introduced (workspace paths and contents, the injected
environment). A marker hit fails the run at the `Harness` stage: a compromised
trial is never scored.

## Trace analysis

`analyze RESULT_DIR` reads each `<task>-<n>/session.json` captured by `run`,
decodes it with the session codec, and writes:

- `analysis/trace-metrics.jsonl` — one flat object per run: task id, run index,
  then every `Trace_metrics` field (token lanes, tool calls and failures,
  per-segment input growth, cache-hit rate, `calls_by_name`, result bytes,
  re-read and repeated-call counts, the longest failure streak, the shell
  command-family histogram, and the recovered model and reasoning effort).
- `analysis/digests/<task>-<n>.txt` — one readable transcript digest per run:
  every step's usage lanes and every tool call with elided arguments and result
  head. The digests are the reviewable form of the session and where new
  hypotheses come from.
- `analysis.md` — a per-run table (joined with each row's success) and a
  per-task behavior-counters table (rereads, repeated calls, longest failure
  streak, and top shell families, summed over the task's runs).

```sh
dune exec spice-eval -- run --suite smoke --model openai/gpt-5.5 --output _evals/results/run1
dune exec spice-eval -- analyze _evals/results/run1
```

`analyze` is idempotent and deterministic: rerunning it rewrites the outputs.
Runs without a `session.json` (the `cmd`, `noop`, `claude`, and `codex`
adapters produce none) are skipped and noted once in `analysis.md`. The
behavior counters exist to measure whether a treatment moved the behavior it
targeted and to check a behavior's baseline prevalence before treating it; they
key on syntactic identity, so a prompt change can zero one without changing
anything real — never treat them as a decision metric.

When `analysis/trace-metrics.jsonl` is present and `report` is given a result
directory, the report appends a compact per-task trace section (mean tokens by
lane, mean tool calls, mean failures).

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
checks record `skipped` and are excluded from the base score. Judge calls run
`--ephemeral`, so they leave nothing in any session store; the subject's own
session lands in the per-run captured `store/`, not the developer's store.

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
- `<task>-<n>/` — per-run artifacts:
  - `workspace/` — the workspace as the agent left it, minus `_build`.
  - `agent.jsonl` — the `spice run --json` event stream, byte-identical.
  - `agent.timing.jsonl` — harness arrival stamps, one `{"line", "ts_ms"}`
    object per stream line (lines arriving in one read chunk share a stamp);
    `analyze` joins it for per-call durations.
  - `session.json` — the captured subject session document (the transcript
    ground truth `analyze` decodes), also archived whole under `store/`.
  - `store/` — the subject's whole per-run data home (sessions, checkpoints,
    todos, goals, blobs): cheap now, unrecoverable later.
  - `git-diff.stdout`, per-command check output, judge prompts/replies.

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
