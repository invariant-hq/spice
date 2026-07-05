Run one non-interactive shell command in a workspace directory.

Prefer the dedicated tools over shell equivalents: read_file over cat and
ls, search_text over grep or rg, glob over find, and the edit tools over sed
or heredocs. Reach for shell when the task is a
real command: builds, tests, git, package managers, running the project's
binaries.

Usage:
- Each call is independent: workdir defaults to the workspace root, and
  shell state does not persist between calls. Chain dependent steps with
  && in one call; put independent commands in parallel calls.
- Quote paths that contain spaces. Keep commands non-interactive; anything
  that prompts for input will hang until the timeout.
- Do not sleep, poll, or retry a failing command unchanged — diagnose the
  failure first.
- The host selects the shell, sandbox, environment, and timeout and output
  bounds. If a command fails because of sandbox restrictions, retry that
  one command with escalate=true and the reason in description; escalation
  needs explicit user approval and is unavailable in read-only runs.
