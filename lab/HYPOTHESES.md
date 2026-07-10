# hypotheses

A living backlog of spice-improvement hypotheses. Each names its treatment
tier (T1 prompt prose; T2 output shaping / error wording / config defaults; T3
tool semantics, new tools, catalog shape — `design-note.md` first), its
primary decision metric (a real resource — tokens, cost, duration — plus
success), and a diagnostic that the trace analysis can corroborate. The
behavior counters in `Trace_metrics` (rereads, repeated calls, failure
streaks, shell families) are diagnostics only, never decision metrics: they
key on syntactic identity and a prompt treatment can zero them without
changing anything real (Goodhart).

Status legend: `open` (not yet screened), `screening`, `candidate`,
`kept`, `discarded`. Update the status and record the measured effect size as
each hypothesis moves.

| # | hypothesis | tier | primary metric | diagnostic | status |
| --- | --- | --- | --- | --- | --- |
| 1 | Tool-doc contrast for code intel | T1 | total tokens | `ocaml_*` call share | open |
| 2 | Diagnostics-first build loop | T1 | tokens per fix | `dune build` shell-family count | open |
| 3 | Result truncation tuning | T2 | input tokens | (guardrail: success) | open |
| 4 | Error messages that name the next move | T2 | duration, tokens | failure streaks; whole-file rewrites | open |
| 5 | Editor family default per model | T2 | edit-failure rate by model | — | open |
| 6 | Merge interchangeable handles | T3 | tokens | calls per step | open |
| 7 | First-turn workspace brief | T3 | tokens before first edit | (guardrail: context size) | open |
| 8 | Doc-writing ground-truth habit | T1 | docs judge scores | — | open |
| 9 | Shell-family tool gaps | discovery | tokens | shell-families counter | open |
| 10 | Extend the provider prompt cache past the static prefix | T3 | fresh (uncached) input per step | per-response `cache_read` growth | open — top priority |
| 11 | Malformed tool-call recovery instead of run abort | T3 | agent-failure rate on local models | provider-error rows | open |
| 12 | Context-discipline prompt rule (rereads/repeats) | T1 | total tokens | `reread-unchanged`, `repeated-call` | discarded |

## Detail

1. **Tool-doc contrast for code intel** (T1). Sharpen the guidance that
   distinguishes `search_text` from `ocaml_find_references` /
   `ocaml_find_definitions` so the model reaches for the semantic tools when
   they apply. Metric: total tokens. Diagnostic (read from the digests):
   `ocaml_*` share of calls, shelling out to grep for identifiers, and
   search-then-read chains.

2. **Diagnostics-first build loop** (T1). Prefer `ocaml_dune_diagnostics` over
   parsing `shell dune build` output. Metric: tokens per fix. Diagnostic: the
   `dune build` share of the shell-families counter.

3. **Result truncation tuning** (T2). Tighter `read_file` / `search_text` caps
   with "refine with…" tails. Metric: input tokens. Guardrail: success must not
   regress (over-truncation starves the model).

4. **Error messages that name the next move** (T2). When a tool fails, the
   message should name the corrective action. Metric: duration and tokens.
   Diagnostic: the failure-streak counter and whole-file rewrites read from the
   digests.

5. **Editor family default per model** (T2). Now runnable because the subject
   config is constructed by the instrument, so a config-default treatment
   actually applies. Metric: edit-failure rate by model.

6. **Merge interchangeable handles** (T3, tool-catalog principle). Collapse
   handles the model treats as interchangeable. Metric: tokens. Diagnostic:
   calls per step. Requires a design note.

7. **First-turn workspace brief** (T3). A one-shot `dune describe` summary in
   turn 1. Metric: tokens before the first edit. Guardrail: context size must
   not balloon. Requires a design note.

8. **Doc-writing ground-truth habit** (T1). Check `ocaml_type_at` / `ocaml_docs`
   before writing doc comments. Metric: docs judge scores.

9. **Shell-family tool gaps** (standing discovery). Recurring families in the
   shell-families counter nominate new `ocaml_*` tools; each becomes its own T3
   hypothesis with a design note.

10. **Extend the provider prompt cache past the static prefix** (T3, top
    priority). Evidence (campaign `g55b`, 2026-07-10, all 18 calibration runs
    on `openai/gpt-5.5`): per-response `cache_read` is pinned at ~10,240
    tokens — exactly the static system-prompt prefix — while the growing
    conversation is re-sent as fresh input on every step (e.g. 544 → 4,754 →
    5,282 → 7,142 → 5,713 → 5,873 across one six-step run). With an extending
    cache, step N re-reads step N−1's prefix from cache and pays only the
    newest tool result fresh. Estimated waste: ~69% of fresh input (~143k
    tokens over 18 S-sized runs), compounding with step count. Suspect:
    volatile bytes at the conversation head in request assembly. Next step is
    a design-note investigation: capture two consecutive request bodies
    (needs a request-dump seam or an HTTP capture), diff the prefixes,
    stabilize the assembly. Metric: per-step fresh input; diagnostic:
    per-response `cache_read` must grow with the conversation.

11. **Malformed tool-call recovery** (T3). On `ollama/gpt-oss:20b`, malformed
    tool-call JSON from the model aborts the whole run
    (`provider: error parsing tool call`), and a dropped stream surfaces as
    `provider_malformed_stream` (campaigns `oss`–`oss3`, several runs each).
    Feeding a structured parse-error result back to the model instead would
    let weak local models retry. Metric: agent-failure rate on local models;
    guardrail: no behavior change on providers with well-formed calls.

12. **Context-discipline prompt rule** (T1, discarded 2026-07-10). "Never
    repeat identical calls; do not re-read unedited files" in system.md Tools.
    Measured: gpt-5.5 (`g55b`, 3 runs/task) median token delta −0.1%, sign
    test 3/6, success 18/18 both arms; gpt-oss (`oss3`, 2 runs/task) +0.0%
    median, success moved 2 tasks in each direction (n=2 noise). Prompt
    admonition alone does not move reread/repeat behavior; if the waste
    matters, it needs a mechanism (e.g. tool-result deduplication, T3), not
    prose.
