# lab program

You are an autonomous researcher improving spice, the OCaml coding agent. You
experiment on spice itself; the eval suite is your measurement instrument. You
never modify the instrument (`eval/`, `lab/`) during a campaign — `spice-lab`
enforces this and you do not work around it. If the instrument is broken, stop
and report.

## Invocation

`spice-lab` runs its own build gate (`dune build bin/main.exe
eval/bin/main.exe`) before every measurement. Because that is a nested `dune`
invocation, do **not** launch it with a plain `dune exec spice-lab -- …` while
no build server is running: `dune exec` takes an exclusive lock on `_build`
and the inner build then deadlocks. Instead either

- build once and call the binary directly (recommended):
  `dune build lab/bin/main.exe && _build/default/lab/bin/main.exe <args>`, or
- keep `dune build --watch` running in another terminal, which turns both the
  outer and inner invocations into build-server clients (no exclusive lock),
  and then `dune exec spice-lab -- <args>` is safe.

The commands below use `spice-lab` as shorthand for the built binary.

## Setup

1. Agree a campaign tag with the user (e.g. `jul10`). Branch `research/<tag>`
   from current main. Campaign data lives under `_lab/<tag>/` (gitignored).
2. Read `HYPOTHESES.md` and the treatment-surface tiers (T1–T3; off-limits is
   off-limits — session/store/protocol core, providers, permissions/sandbox,
   and the instrument itself).
3. Calibrate the campaign baseline and pin the instrument:

   ```
   spice-lab calibrate --campaign <tag> --suite core --runs 5 [--model <m>] [--agent <a>]
   ```

   This records `campaign.json` (start ref, baseline binary digest, and a
   content digest of `eval/`+`lab/` that freezes the instrument), runs the
   baseline arm into `_lab/<tag>/calibration/<ts>/`, and writes
   `calibration/noise.json` plus a per-task noise summary (success counts and,
   over completed runs, token and duration median/min/max) and the per-run
   mean wall-clock for night budgeting. Fill the calibrated numbers below from
   its output.

4. Run the A/A canary — a baseline-vs-baseline arm through the full
   screen→verdict pipeline — to measure the false-candidate rate the decision
   rules actually produce:

   ```
   spice-lab experiment run --campaign <tag> --name aa --suite core --runs 5 --aa [--model <m>] [--agent <a>]
   spice-lab experiment compare --campaign <tag> aa
   ```

   The A/A must not come out `candidate`. If it does, the thresholds are too
   loose for the measured noise; raise them before screening anything.

5. Confirm budget with the user: per-experiment and campaign ceilings (tokens
   and wall-clock; cost only if the model is metered).

Note on suites: the curated `screen`/`confirm` suites (with holdouts) arrive
with the reference-anchored corpus (spec §6.7, §9 Phase 3). Until then use the
existing suites — `smoke` (single micro task, cheap smoke test), `core`
(the standard micro corpus), `long`, `robustness`, `all`. Treat `core` as the
screening suite and `all` as the confirmation suite, and record the suite in
every ledger row so the choice is auditable.

## The experiment loop

LOOP until budget is exhausted or the user stops you:

1. **Review transcripts first — hypotheses come from session evidence, not
   introspection.** Read the per-run transcript digests under the most recent
   arm's `analysis/digests/` (the calibration arm on the first iteration): at
   minimum the most expensive run per task, every failed run's digest, and
   one success for contrast. A digest shows each step's usage lanes
   (`in`/`out`/`reason`/`cache_r`/`cache_w`) and each tool call with its
   arguments and result head — the patterns that matter are visible only
   here: a pinned `cache_r` while `in` grows, an oversized tool result
   injected into context, a give-up after two steps, a missing verification
   step. Detectors catch only what they were taught to see; the digests are
   where new hypotheses and new detector ideas come from. Record every
   observation in `HYPOTHESES.md` with an evidence pointer
   (campaign/arm/task/run and step numbers).
2. Pick the highest-value open hypothesis from `HYPOTHESES.md`. Apply the
   treatment on the branch. T3 requires a `design-note.md` in the experiment
   dir first (problem, alternatives, `.mli` sketch; load the relevant
   `ocaml-*` design skill). Commit.
3. Screen:

   ```
   spice-lab experiment run --campaign <tag> --name <n> --suite core --runs 3 [--model <m>]
   spice-lab experiment compare --campaign <tag> <n> [--threshold <pct>]
   ```

   `experiment run` gates the build itself and refuses to measure a binary
   whose digest equals the baseline (pass `--allow-identical-binary` only if
   you know the change is data-only). `experiment compare` pairs per task on
   the task-set intersection under the pre-registered estimand and prints the
   verdict; it exits 0 on `candidate`, 1 on `discard`, 2 on `partial`/error.
4. Read `_lab/<tag>/exp/<n>/compare.md`, `analysis.md`, and the treated arm's
   digests for at least the tasks whose numbers moved — in either direction. A
   treatment that "worked" for the wrong reason (shorter because it stopped
   verifying) and one that "failed" for an interesting reason (a new
   behavior the metric does not reward) both only show up in the transcript.
   Harvest into `HYPOTHESES.md`.
5. Candidate → confirm on the larger suite, and record the ledger row:

   ```
   spice-lab experiment run --campaign <tag> --name <n>-confirm --suite all --runs 5 [--model <m>]
   spice-lab experiment compare --campaign <tag> <n>-confirm
   spice-lab ledger add --campaign <tag> --name <n>-confirm \
     --verdict keep|discard --hypothesis "<H>" --tier T1|T2|T3 \
     --primary-metric tokens [--treatment "<what changed>"] [--expected "<effect>"]
   ```

   Keep iff the confirm verdict says keep and the effect persists at ≥ half its
   screen size.
6. Keep → the branch advances. Discard → `git reset` to the pre-treatment
   commit. Build failure → `experiment run` writes a `crash` ledger row and
   exits non-zero; reset and move on.
7. Every experiment gets a ledger row, including discards and crashes.
   `spice-lab ledger list --campaign <tag>` renders the table; `ledger.md` is
   regenerated on every append.
8. Every 5 keeps: compounding audit (tip vs campaign start, `--suite core
   --runs 3`). If cumulative gains do not hold, say so and re-examine the kept
   set.

Do not pause to ask whether to continue. Self-stop only for: budget exhausted,
compounding-audit failure, instrument breakage. There is no "out of ideas"
state: step 1 always runs against fresh transcripts, and unreviewed digests
are unread evidence.

## Decision rules (defaults; the numbers below own the thresholds)

- Primary metric: the per-task median of total tokens (`input_total +
  output_total`) over all completed runs, with failed/timed-out runs imputed
  at the worst value observed for that task across both arms. Duration is
  computed the same way and reported; success is per-task counts.
- Tripwire: any task all-pass in the reference and all-fail in the candidate →
  `discard`.
- Guardrail: success dropping on ≥2 tasks → `discard` regardless of the
  primary metric.
- Candidate: primary-metric improvement (median of per-task deltas) ≥ the keep
  threshold; the per-task sign test (improved in K of N tasks) is reported
  alongside.
- Partial: a verdict computed over a proper subset of the paired suite is
  downgraded to `partial` and can never be a keep.
- When token usage is absent on both arms (e.g. the `cmd`/`noop` adapters),
  the primary metric is unavailable and the verdict falls back to a
  success-only comparison, which says so.

## Blindness rules (absolute)

- Never put evaluation markers where the subject can see them: no editing
  fixtures/corpus, no prompt text referencing evals, benchmarks, or graders.
  Treatments change how spice works, not what it is told about being measured.
- Never read a subject session mid-run; analyze completed artifacts only.

## Calibrated numbers (fill at setup)

- screening suite: `core` (__ tasks); per-run wall-clock ~__s; success noise
  ε = __; A/A false-candidate rate = __
- guardrail detection limit at n=5: ~__ points (state it, accept it)
- keep threshold: primary metric ≥ __% improvement persisting in confirm
- budget: __ tokens / experiment; __ h / night; $__ if metered
- model under test: __ (first campaigns: local `gptoss` via the ollama
  provider — token cost ≈ 0, wall-clock is the binding constraint)
