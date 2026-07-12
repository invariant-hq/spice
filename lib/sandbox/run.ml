(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.sandbox.run" ~doc:"Sandbox sealing and spawn decisions"

module Log = (val Logs.src_log log_src : Logs.LOG)

let network_name = function
  | Policy.Network.Restricted -> "restricted"
  | Policy.Network.Enabled -> "enabled"

type escalation = Available | Denied of Error.t | Ignored

module Spawn = struct
  type t = {
    argv : Argv.t;
    env : (string * string) list;
    evidence : Evidence.t;
  }

  let argv t = t.argv
  let env t = t.env
  let evidence t = t.evidence
end

type decision =
  | Unconfined
  | Declared_external
  | Confine of { prepared : Backend.prepared; evidence : Evidence.t }
  | Refuse of Error.t

type t = { policy : Policy.t; decision : decision; escalation : escalation }

let default_backend =
  lazy (Backend.none ~reason:"no sandbox backend configured")

let read_only_escalation_reason =
  "escalation is not available in a read-only sandbox: read-only runs do not \
   mutate; rerun with --sandbox workspace-write for mutating work"

let read_only_escalation_error =
  lazy (Error.invalid_request read_only_escalation_reason)

let confined ?backend policy =
  let backend =
    match backend with
    | Some backend -> backend
    | None -> Lazy.force default_backend
  in
  let escalation =
    match Policy.writable_roots policy with
    | [] -> Denied (Lazy.force read_only_escalation_error)
    | _ :: _ -> Available
  in
  Log.debug (fun m ->
      m "sealing confinement backend=%s writable_roots=%d network=%s"
        (Backend.id backend)
        (List.length (Policy.writable_roots policy))
        (match Policy.network policy with
        | Some network -> network_name network
        | None -> assert false));
  let decision =
    match Backend.available backend with
    | Error reason ->
        Log.warn (fun m ->
            m "sandbox backend unavailable, confinement refused backend=%s: %a"
              (Backend.id backend) Error.pp reason);
        Refuse reason
    | Ok () -> (
        match Backend.prepare backend policy with
        | Error reason ->
            Log.warn (fun m ->
                m
                  "sandbox backend preparation failed, confinement refused \
                   backend=%s: %a"
                  (Backend.id backend) Error.pp reason);
            Refuse reason
        | Ok prepared ->
            Log.debug (fun m ->
                m "confinement enforceable backend=%s profile=%s"
                  (Backend.id backend)
                  (Spice_digest.to_hex (Backend.profile prepared)));
            Confine
              {
                prepared;
                evidence =
                  Evidence.enforced ~backend:(Backend.id backend)
                    ~profile:(Backend.profile prepared);
              })
  in
  { policy; decision; escalation }

let seal ?backend policy =
  match policy with
  | Policy.Direct _ -> { policy; decision = Unconfined; escalation = Ignored }
  | Policy.External _ ->
      { policy; decision = Declared_external; escalation = Ignored }
  | Policy.Confined _ -> confined ?backend policy

let policy t = t.policy

let spawn t ~argv:command_argv =
  let environment = Environment.bindings (Policy.environment t.policy) in
  match t.decision with
  | Unconfined ->
      Ok
        Spawn.
          {
            argv = command_argv;
            env = environment;
            evidence = Evidence.not_requested;
          }

  | Declared_external ->
      Ok
        Spawn.
          {
            argv = command_argv;
            env = environment;
            evidence = Evidence.declared_external;
          }
  | Refuse error -> Error error
  | Confine { prepared; evidence = command_evidence } ->
      let wrapped_argv = Backend.wrap prepared ~argv:command_argv in
      Log.debug (fun m ->
          m "confined spawn program=%s environment_names=%d"
            (Argv.program command_argv)
            (List.length (Environment.names (Policy.environment t.policy))));
      Ok
        Spawn.
          {
            argv = wrapped_argv;
            env = environment;
            evidence = command_evidence;
          }

let spawn_escalated t ~argv:command_argv =
  match t.escalation with
  | Available ->
      Ok
        Spawn.
          {
            argv = command_argv;
            env = Environment.bindings (Policy.environment t.policy);
            evidence = Evidence.not_requested;
          }
  | Denied error -> Error error
  | Ignored ->
      Error
        (Error.invalid_request
           "sandbox escalation is not meaningful for this execution route")

let escalation t = t.escalation

let evidence t =
  match t.decision with
  | Unconfined -> Evidence.not_requested
  | Declared_external -> Evidence.declared_external
  | Confine { evidence; _ } -> evidence
  | Refuse error -> Evidence.refused error
