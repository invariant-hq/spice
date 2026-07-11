# lab program: design review campaign

You are the orchestrator of a design review campaign over one spice library.
Six specialist subagents review it in parallel, each through one lens; you
synthesize their reports on first-principles merit; a change plan is designed
and then attacked by an adversarial agent; the human approves it; you
implement it one commit per task. The human sits at exactly two judgment
points — after the synthesis and after the adversarial pass — and you never
change code before the second one.

The campaign's goal, verbatim policy for every stage: identify issues and
improvements **that deserve a commit**. We do not make changes for the sake
of changes, and "a lot of churn" is not a reason to discard an improvement —
the human prices churn at plan approval; you never pre-filter on it silently.
A campaign that ends with zero worthwhile changes is a valid outcome, said
plainly.

Read this program in full before starting; it is self-contained.

## Setup (once per campaign)

Agree with the launcher on the **target** — one library, e.g. `lib/session`
— and derive the tag `review-<target>-<date>`. Then:

1. You run where the launcher put you, on the current branch — supervised,
   in the main checkout. Never create worktrees or branches unless asked.
   Main-tree etiquette binds: dune may be running in watch mode (never kill
   it, never take its lock — build as a client), promotion is always scoped
   (`dune promote <file>`, never bare), and co-editors may have uncommitted
   work (never checkout, reset, or restore anything).
2. Read `_lab/notes/` entries for this target if any exist (from prior bug
   sessions or campaigns) — refuted suspicions, immaterial findings,
   landmines. Do not re-litigate them.
3. Reports live in `doc/reviews/<target>/` — ephemeral working documents,
   like plans: never committed. Create the directory.

## Stage 1 — the panel

Launch six subagents in parallel. Each reads the target library in full —
every `.mli`, every `.ml`, its tests, its callers across the repo — loads
its lens skill, and writes `doc/reviews/<target>/<lens>.md`:

| lens | skill | looks for |
| --- | --- | --- |
| library design | `ocaml-library-design` | waist shape, module composition, extension seams |
| module/API design | `ocaml-module-design` | core types, constructors/eliminators, error shapes, `.mli` contracts |
| implementation | `ocaml-tidy` | clarity, density, locality in the `.ml`s |
| documentation | `ocaml-doc` | contract completeness, accuracy, style; the `.mli` is the source of API truth |
| testing | `ocaml-testing` | right test level, contract coverage, missing properties |
| bugs | — | contract violations, error paths, edge cases, ripple misses |

Every brief must state, explicitly:

- **Read-only.** The panel changes nothing — no edits, no fmt, no promote,
  no builds beyond what reading requires, no background loops, no pipelines
  that mask exit codes.
- **Evidence or it does not exist.** Every finding carries a pointer —
  file:line, a caller list, a quoted contract — and states what is, what
  should be, and why the gap deserves a commit.
- **Both directions.** The report opens with a merit judgment of the library
  against the lens — what is genuinely right is as load-bearing for the
  synthesis as what is wrong — and closes with a checked-and-sound list, so
  synthesis knows what was covered, not just what was flagged.
- **Repo conventions bind the lens.** AGENTS.md's api design rules are part
  of the design lenses' rulers. The testing lens judges against this repo's
  test philosophy — host behavior is cram-blackbox through the spice binary,
  TUI is pty-only, unit tests only for pure code, one test file per lib —
  not against generic best practice.

## Stage 2 — the synthesis

Read every report in full, then write `doc/reviews/<target>/synthesis.md`:

- **Verify before believing.** Panel reports can be wrong exactly like any
  agent output: spot-check every load-bearing claim against the code before
  it drives a recommendation.
- **Deduplicate across lenses.** A defect three lenses report is one finding
  with three witnesses — stronger, not triple.
- **Judge on first-principles merit** — what this library *should* be, not
  what it takes to get there. Discard only for lack of merit; never for
  churn, and never because the current shape is merely familiar.
- **Provenance before deletion.** Anything the synthesis marks as dead or
  redundant gets a provenance check first — `git log -S`, plans, the named
  consumer — because unused may mean extension point or product gap, not
  cruft.

Deliver the synthesis to the launcher: what we should do, ranked, with what
you rejected and why. **Stop here until the human responds.**

## Stage 3 — the plan, adversarially reviewed

From the approved synthesis, design the change plan, working against the
`ocaml-module-design` skill (and `ocaml-library-design` when the shape of the
family is in question). The governing principle is the
**simplification-convergence signal**: for every issue, first ask whether it
dissolves under a simpler design rather than another layer. When one change
both simplifies the design and removes issues, that is evidence we are
converging on the right design — those changes lead the plan. A plan whose
every item adds a type, a layer, or a knob is evidence of the opposite;
reconsider before presenting it.

Rules of the plan:

- One task per commit-sized change, in dependency order, each naming the
  files it touches, the `.mli` deltas, the callers it updates, and the tests
  that prove it.
- **Bug findings do not skip verification.** Each fix-worthy bug finding
  gets a minimal repro that fails on the unmodified tree before its fix
  enters the plan (the `lab/programs/bugs.md` gate); unreproducible ones are
  carried in the synthesis as reports, not fixed on faith. The materiality
  gate applies too: no mechanisms for theoretical defects.
- Behavior changes are named as such, never smuggled inside refactors.

Then launch an **adversarial agent** whose brief is to break the plan:
verify each diagnosis is actually true in the code; hunt for missed callers
and hidden behavior changes; propose the simpler alternative for any task
that adds structure; say which tasks it would cut. Fold its findings in —
correct, improve, or augment — and present the final plan with the
adversary's unresolved objections attached, not silently dropped.

**Stop here until the human approves the plan.**

## Stage 4 — implementation

Implement the approved plan in order, one commit per task:

- `.mli`-first for any signature change; build green and the target's
  targeted tests green before each commit — never a bare `@runtest`.
- Callers updated in the same commit. No aliases, no compat shims: obsolete
  concepts are deleted and old shapes fail loudly, per AGENTS.md.
- Stage only task-owned paths — the worktree may hold concurrent work that
  is not yours.
- Commit messages per the repo guidelines: causality first — the prior
  behavior and why it mattered, the new shape and where the invariant now
  lives. The campaign is not chronology worth recording; write for a reader
  who never saw `doc/reviews/`.
- When implementation proves a task wrong — the diagnosis missed something,
  the simpler design does not hold — stop that task, say so, and re-plan
  with the human. Never improvise a divergent design mid-implementation, and
  never paper over a failing test to keep the plan on schedule.

## Session end

- Report to the launcher: tasks landed with commit hashes, tasks stopped and
  why, reports carried (unreproducible bugs, upstream findings).
- Append negative knowledge to `_lab/notes/review-<target>.md`: claims the
  synthesis refuted, improvements judged not worth a commit and why — so the
  next campaign or bug session does not re-litigate them.
- `doc/reviews/<target>/` stays uncommitted and is the launcher's to sweep.
  Anything durable a campaign taught us belongs in `doc/dev/` or the manual,
  distilled — the human decides.

## Validity (absolute)

- **The failure mode is plausible-sounding redesign** that trades working
  code for aesthetics. The deserve-a-commit bar, the adversarial pass, and
  the human at both judgment points exist to stop it; do not argue around
  them.
- **Upstream at source.** A defect in one of the human's own libraries
  (mosaic, windtrap, thumper, …) is fixed there, never worked around in
  spice: the plan carries it as an upstream task, executed in a fresh
  **clone** of that repo — never in the human's local checkout. The
  repository URL comes from the dep's entry in spice's `dune.lock`
  (`(source (fetch (url …)))`); clone, branch `lab/<tag>`, `dune pkg lock`,
  `dune build`, then fix under that repo's own conventions and tests, one
  commit with fix + repro, left in the clone for the human to fetch, push,
  and relock. If the defect is already fixed past spice's pinned rev, the
  task reduces to a relock. Spice tasks that depend on the upstream fix
  sequence after the relock. Truly third-party deps get a report with a
  proposed fix; upstream PRs are human-led.
- **Guideline conformance, not taste.** Every design finding cites the rule
  it enforces — a skill, AGENTS.md, or a stated repo convention. "Feels
  complex" is not a finding; a call site that gets simpler is.
