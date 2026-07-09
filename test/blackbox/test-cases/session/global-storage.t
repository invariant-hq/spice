Sessions are global durable data while ordinary discovery stays scoped to the
exact canonical cwd.

  $ mkdir project-a project-b
  $ git -C project-a init -q
  $ git -C project-b init -q
  $ cd project-a
  $ spice session create --id cross-project --title Cross
  cross-project
  $ test ! -e .spice && echo no-project-output
  no-project-output
  $ cd ../project-b

The other project can address an explicit global id, but its default listing
does not include that session. --all widens only the read scope.

  $ spice session list | grep cross-project || echo hidden
  hidden
  $ spice session list --all | grep cross-project | sed -E 's/  +/ /g'
  cross-project idle just now $TESTCASE_ROOT/project-a Cross
  $ spice session show cross-project | grep '^cwd:'
  cwd: $TESTCASE_ROOT/project-a

Continuation bootstraps from the recorded cwd. An explicit --cwd is an
assertion, so a mismatch fails before changing the document.

  $ before=$(cksum < "$SPICE_TEST_DATA_HOME/sessions/cross-project/session.json")
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume cross-project
  spice: run resume requires PROMPT when no turn is active
  [2]
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume --cwd "$PWD" cross-project
  spice: --cwd '$TESTCASE_ROOT/project-b' does not match the session cwd '$TESTCASE_ROOT/project-a'
  [2]
  $ after=$(cksum < "$SPICE_TEST_DATA_HOME/sessions/cross-project/session.json")
  $ test "$before" = "$after" && echo unchanged
  unchanged

A missing recorded cwd fails before runtime assembly or session mutation.

  $ mv ../project-a ../project-a-moved
  $ SPICE_MODEL=openai/gpt-5.5 spice run resume cross-project
  spice: session cwd is not an existing directory: $TESTCASE_ROOT/project-a
  [1]
