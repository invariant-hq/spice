Delegate bounded work to a child session with a fresh context. The host
decides whether the requested role is allowed.

The child runs detached: this call returns immediately with the child's
session id, and you keep working while it runs. Its result arrives as a
notice; call wait_subagents with the session id when your next step
needs the result before you can continue. Steer a running child, answer
its question, or resume a finished one for follow-up work with
message_subagent — a resumed child keeps its context, so prefer that
over respawning and re-briefing. Cancel a run you no longer need with
cancel_subagent.

Roles:
- explore — read-only search and reading; returns findings with paths.
  Use for open-ended investigation across many files where you need the
  conclusion, not the file contents, in your context.
- review — read-only inspection of an assigned surface; returns
  severity-ordered findings.
- verify — runs checks through the shell (build, tests, probes) and
  returns evidence with a PASS, FAIL, or PARTIAL verdict.

Do not spawn for needle queries: a known file → read_file; a specific
symbol or string → search_text; a couple of known files → read them
directly.

The subagent has not seen this conversation. Brief it like a colleague
who just walked in: the goal and why, the relevant paths, what you
already ruled out, and exactly what its final message must contain —
including how thorough to be (a quick look at one area vs an exhaustive
sweep across naming conventions and locations). Do not delegate
synthesis you have not done ("figure out what matters and fix it");
delegate questions or checks you can state precisely. An explore child
locates and summarizes; it does not judge or audit — keep verdicts for
review and verify.

Independent delegations go in one response, in parallel; wait for them
in one wait_subagents call. Do not redo the delegated work yourself
while waiting. The subagent's output is not shown to the user — relay
what matters in your own message. Do not end your turn while a spawned
result you need is still pending.
