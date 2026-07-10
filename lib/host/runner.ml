(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  store : Spice_session_store.t;
  client : Spice_llm.Client.t;
  model : Spice_llm.Model.t;
  mode : Spice_protocol.Mode.t option;
  run : Spice_session_run.Config.t;
  host_tool : Handler.t;
  resolve_plan : Session_loop.plan_resolver;
  compaction : Compactor.Policy.t option;
  hooks : Session.hooks;
}

let no_handler ~cancelled:_ _document _call = Ok None

(* A runner built without a plan resolver cannot resolve a [propose_plan]
   boundary: a [Resolve_plan] command against it is a configuration error, never
   a silent no-op. The runners that host plan-mode turns supply the real
   resolver; a subagent runner (whose [Handler.subagent] refuses plans) keeps
   this. *)
let no_resolver ~decision:_ _proposal =
  Error (Spice_protocol.Error.Internal "plan resolution is not configured")

let make ~store ~client ~model ~mode ~run ?(host_tool = no_handler)
    ?(resolve_plan = no_resolver) ?compaction ?(hooks = Session.no_hooks) () =
  { store; client; model; mode; run; host_tool; resolve_plan; compaction; hooks }

let with_hooks f t = { t with hooks = f t.hooks }

let execute t document command =
  Session_loop.execute ~store:t.store ~client:t.client ~host_tool:t.host_tool
    ~resolve_plan:t.resolve_plan ~turn_model:t.model ~turn_mode:t.mode ~run:t.run
    ?compaction:t.compaction ~hooks:t.hooks document command
