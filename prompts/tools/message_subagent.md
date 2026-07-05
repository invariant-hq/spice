Send a message to a subagent run: steer it, answer its question, or
resume it for follow-up work.

Delivery is immediate from your side and never blocks. A running
subagent sees the message before its next step. A subagent that asked
you something via message_parent resumes with your message as the
answer. A settled subagent resumes with a new turn carrying your
message — its context is intact, so message it for follow-ups instead
of spawning a fresh child and re-briefing from zero.

If a running subagent finishes without acting on a message you sent,
message it again to resume it.
