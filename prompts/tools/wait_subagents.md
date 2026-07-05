Block until the named subagent runs settle and return their results.

Spawned subagents run detached: spawn_subagent returns immediately with
a run id, you keep working, and results arrive as notices. Call this
tool only when your next step needs a result you have not received yet
— pass every run id you are blocked on in one call, not one call per
run.

A blocked or failed run returns its blocker or failure message; a
cancelled run reports that it was cancelled. Waiting on a run that
already settled returns its recorded result again.
