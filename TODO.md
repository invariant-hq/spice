# todo

- review this health reload thing from tui next, why are we doing this in the tui?! the dune build should be a host concern, for the tui this is just notifications? Like the tools
- fix the sandbox issue when running dune build (this is a security+design task)
  - somewhat fixed, but need a good review of our sandbox/permission semantics. UX is really bad now.
- consider always using a local model (e.g. gpt oss) as a small model for titles, for what the subagents are doing to display in the subagent view tui, for recap in the transcript, etc.
- consider owning a dune rpc that builds in a separate build dir so we don't conflict with tools like describe projects that are incompatible with dune rpc running. Gives us both live diagnostics, and doesn't block running incompatible dune commands
- improve the eval and drive inspection of sessions to fix issues
  - consider task specific evals like docs and design that have a reference to test against
- consider augmenting describe to give module tree per library. and other useful info?

## to fix

- composer cursor not blinking (possibly bug fix to make in mosaic/matrix, runtime fix in matrix didn't fix it)
- on resize, inserts a massive blank space that is several screen high, sometimes, need a repro
- why are the dialogs taking all the height?
- tab to switch agents (build/plan) (?) we have shift+tab to switch permission mode
  - this is a UX question, what's the right UX here?
- implement text selection (see for claude code semantics. or maybe just say Shift select is enough)
  - claude code text selection is different than opencode, and feels more like the native terminal. See how they do that.

## next

- knowledge base?
- linter
- runbook with doc
- eval suite expansion to non-trivial tasks
- ? client/server architecture with web ui
- runbooks/workflows? (design,doc,tidy)
