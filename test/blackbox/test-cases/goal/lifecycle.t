Goal lifecycle verbs are session-scoped run continuations over the stored
artifact. This fixture parks a goal continuation turn on a question, leaving an
active goal with no driver — a normal projected state — then exercises the
verbs against it.

  $ cat > goal.jsonl <<'JSONL'
  > {"expect":{"body_contains":["\"name\":\"update_goal\""]},"response":{"id":"resp-1","status":"completed","model":"gpt-5.5","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"First pass done."}]}]}}
  > {"expect":{"body_contains":["Continue working toward the active session goal."]},"response":{"id":"resp-2","status":"completed","model":"gpt-5.5","output":[{"type":"function_call","id":"item-q","call_id":"q-1","name":"ask_user","arguments":"{\"question\":\"Which port should the server use?\"}"}]}}
  > JSONL
  $ start_fake_openai goal.jsonl goal-capture goal-port

A parked goal turn exits with the blocked convention; the goal stays active.

  $ spice run --cwd "$PWD" --permission-mode bypass --id goal-life --goal "Ship it" 2>&1 | sed -E 's/turn_[-0-9_]+/turn_$ID/g; s/goal_[-0-9_]+/goal_$ID/g'
  permission: bypass
  sandbox: danger-full-access (config)
  backend: none not_requested
  network: enabled
  warning: command sandbox disabled by explicit user choice
  spice: goal goal_$ID: active — Ship it
  spice: goal: continuing (turn 1)
  spice: session goal-life waiting: user question call=q-1 question='Which port should the server use?'
  answer: spice run reply 'goal-life' --question 'q-1' --answer TEXT
  [3]
  $ wait_fake_server

The parked session projects the active goal and the continuation turn's
origin.

  $ spice session show goal-life | grep '^goal:'
  goal: active — Ship it

Goal verbs are artifact operations: pause needs no model or credentials.

  $ spice run reply goal-life --pause-goal 2>&1 | sed -E 's/goal_[-0-9_]+/goal_$ID/g'
  spice: goal goal_$ID: paused — Ship it
  spice: resume the goal with: spice run reply goal-life --resume-goal

Verbs the status does not admit fail without mutation.

  $ spice run reply goal-life --pause-goal 2>&1 | sed -E 's/goal_[-0-9_]+/goal_$ID/g'
  spice: cannot pause goal goal_$ID while it is paused
  [1]

Editing replaces the objective in place and keeps the status.

  $ spice run reply goal-life --edit-goal "Ship it faster" 2>&1 | sed -E 's/goal_[-0-9_]+/goal_$ID/g'
  spice: goal goal_$ID: paused — Ship it faster
  $ spice session show goal-life | grep '^goal:'
  goal: paused — Ship it faster

Clearing is terminal; later verbs report the terminal state.

  $ spice run reply goal-life --clear-goal 2>&1 | sed -E 's/goal_[-0-9_]+/goal_$ID/g'
  spice: goal goal_$ID: cleared — Ship it faster
  $ spice run reply goal-life --pause-goal 2>&1 | sed -E 's/goal_[-0-9_]+/goal_$ID/g'
  spice: cannot pause goal goal_$ID while it is cleared
  [1]
  $ spice session show goal-life | grep -c '^goal:'
  0
  [1]

Flag validation fails before credentials and before mutation.

  $ spice run reply goal-life --pause-goal --clear-goal
  spice: choose only one of --pause-goal, --resume-goal, --edit-goal, or --clear-goal
  [2]
  $ spice run reply goal-life --pause-goal --allow perm_1
  spice: a goal verb cannot be combined with another continuation
  [2]
  $ spice run reply goal-life --clear-goal --goal-budget 100
  spice: --goal-budget requires --resume-goal
  [2]
  $ spice run --cwd "$PWD" --goal-budget 100 "no goal"
  spice: --goal-budget requires --goal
  [2]
  $ spice run --cwd "$PWD" --mode plan --goal "read-only goals are refused" "x"
  spice: --goal requires build mode
  [2]
  $ spice run --cwd "$PWD" --goal "" "empty objective"
  spice: goal objective must not be empty
  [1]
