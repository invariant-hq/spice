# Eval task rubric

This rubric is the admission checklist for tasks in the Spice eval corpus.
The goal is to measure whether an agent produces work a real Spice user would
accept, not whether it can exploit a fixture.

## Suite tiers

- `smoke` catches harness failures and catastrophic agent regressions. Tasks
  are tiny, deterministic, and fast.
- `core` represents common user workflows: bugfixes, tests, docs, refactors,
  features, build/tooling, and comprehension tasks.
- `long` is for multi-step engineering work with larger edit surfaces or
  several dependent subtasks.
- `robustness` is for adversarial and UX-sensitive tasks: tempting shortcuts,
  noisy evidence, ambiguity, permission boundaries, and hidden traps.
- `all` is the union of the tier suites.

## Admission criteria

Every task should satisfy all of these before it becomes a benchmark task.

1. Clear prompt

   A competent engineer can infer the expected result from the prompt and the
   workspace. The prompt should be phrased like a real user request, not like a
   benchmark instruction.

2. Valid oracle

   Checks accept reasonable correct solutions and reject obvious bad ones.
   Prefer objective gates over judge checks. Use judge checks only for quality
   dimensions that objective checks cannot capture.

3. No accessible answer key

   The final answer should not be recoverable from fixture names, committed
   reference patches, visible tests, comments, or evaluator-only files copied
   into the workspace.

   Hidden shell checks in `eval/bin/corpus.ml` are hidden from the task
   workspace, not from a malicious full-filesystem agent. Treat them as
   anti-overfitting checks for normal black-box agents. For adversarial
   comparisons, store oracle material outside the repository checkout or run
   agents with filesystem access restricted to the task workspace and required
   toolchain paths.

4. Realistic workflow

   The task should resemble something a user would ask a coding agent to do in
   a repository: fix, extend, refactor, document, test, investigate, or repair
   build/tooling behavior.

5. Deterministic environment

   The task should not depend on the current date, network access, random
   behavior, mutable external services, or unpinned dependencies.

6. Scoped blast radius

   The expected solution has a reasonable edit size. Forbidden areas are
   explicit when scope matters, and scope checks penalize unrelated churn.

7. Reviewable failure

   A failed row should explain what failed through structured findings and
   artifacts. If an agent fails, maintainers should be able to tell whether the
   problem was setup, agent behavior, checks, judge, or harness.

## Required task metadata

Each task should set:

- `tier`: `smoke`, `core`, `long`, or `robustness`
- `category`: `bugfix`, `feature`, `refactor`, `interface`, `docs`, `build`,
  `tests`, or `comprehension`
- `size`: `S`, `M`, or `L`
- `oracle`: a compact label such as `checks`, `hidden-tests`, `judge`, or
  `checks+judge`

Use tags for filtering and metadata for report slicing. Tags should include the
tier, category, and size.

## Check design

Use this order by default:

1. Build/test gates that define task success.
2. Scope gates or penalties for forbidden edits.
3. Policy penalties, such as warning suppression or broad rewrites.
4. Judge checks for quality dimensions that cannot be objectively tested.

Gate failures short-circuit later checks in the runner. A task that needs a
quality judge should still have objective gates that establish basic correctness.

## Reporting expectations

Do not compare agents by a single score alone. Reports should be read across:

- success rate
- mean final score
- score variance
- missing-quality rate
- duration
- turns and tool calls
- cost of success
- wasted cost
- failure-stage distribution

Important tasks should be run multiple times. Reliability matters: an agent that
passes once and fails twice is not equivalent to an agent that passes
consistently at similar cost.
