Interrupt a running subagent.

Use this when a run's task is no longer needed — the plan changed, its
question was answered elsewhere, or a sibling already produced the
result. Cancellation is a neutral outcome, not a failure: the run
settles as cancelled and any partial work in its session remains
inspectable.

Cancellation is idempotent: cancelling an already cancelled run returns its
recorded result without another transition. Cancelling a run that already
completed or failed is an error and changes nothing.
