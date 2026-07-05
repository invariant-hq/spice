Interrupt a running subagent.

Use this when a run's task is no longer needed — the plan changed, its
question was answered elsewhere, or a sibling already produced the
result. Cancellation is a neutral outcome, not a failure: the run
settles as cancelled and any partial work in its session remains
inspectable.

Cancelling a run that already settled is an error and changes nothing.
