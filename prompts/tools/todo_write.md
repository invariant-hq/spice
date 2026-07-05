Replace the visible todo list for the current session. Use it to track
implementation progress on work with three or more distinct steps, or
when the user gives several tasks at once. Skip it for a single
straightforward task — just do the task. It does not approve plans.

Usage:
- Omit `owner` or use `owner: "main"` for the main thread. Positions are
  zero-based and contiguous per owner.
- Keep at most one todo `in_progress` per owner: mark a step in_progress
  when you start it and completed as soon as it is done — never batch
  completions after the fact.
- Never mark a step completed while its checks fail or its work is
  partial; keep it in_progress and add a todo describing the blocker.
