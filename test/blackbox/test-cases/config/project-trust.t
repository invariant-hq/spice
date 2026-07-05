Project config applies without a trust decision.

Workspace config layers load unconditionally; safety comes from the
allowlist filter, not from a trust gate.

  $ spice config set --project model openai/gpt-5.4
  $ spice config get model
  openai/gpt-5.4

  $ spice config show --json --origins | grep -o '"diagnostics":\[\]'
  "diagnostics":[]

The trust store still records decisions, but says plainly that nothing
consumes them yet.

  $ spice trust .
  trusted $TESTCASE_ROOT
  note: trust currently gates nothing; project config always loads with workspace-safe filtering. The decision is recorded for future trust-gated features.

  $ spice config get model
  openai/gpt-5.4

  $ spice untrust .
  untrusted $TESTCASE_ROOT
  note: trust currently gates nothing; project config always loads with workspace-safe filtering. The decision is recorded for future trust-gated features.

  $ spice config get model
  openai/gpt-5.4
