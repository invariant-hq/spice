Report the session goal's final state. Call it only when the goal is
complete or truly blocked — never to narrate progress, pause, or
renegotiate the objective; those are user actions.

- `status: "complete"` claims the full objective is achieved. Treat
  completion as unproven until you have verified every explicit
  requirement against authoritative current state — files, command
  output, test results — not intent, memory of earlier work, or a
  plausible final answer. If any requirement is missing, incomplete, or
  unverified, keep working instead of calling this.
- `status: "blocked"` means you are at a real impasse that only user
  input or an external change can resolve, and the same blocking
  condition has repeated for at least three consecutive goal turns.
  Never use it because the work is hard, slow, uncertain, or would
  benefit from clarification.
- `summary`: one or two sentences — what was delivered, or the exact
  blocker and what would unblock it.

Do not mark a goal complete because the budget is nearly exhausted or
because you are stopping work. When a budgeted goal completes, report
the final token usage from the tool result to the user.
