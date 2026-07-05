(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.sandbox.run" ~doc:"Sandbox sealing and spawn decisions"

module Log = (val Logs.src_log log_src : Logs.LOG)

let network_name = function
  | Confinement.Restricted -> "restricted"
  | Confinement.Enabled -> "enabled"

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

type t = { decision : decision; escalation : escalation }

let default_backend =
  lazy (Backend.none ~reason:"no sandbox backend configured")

let read_only_escalation_reason =
  "escalation is not available in a read-only sandbox: read-only runs do not \
   mutate; rerun with --sandbox workspace-write for mutating work"

let read_only_escalation_error =
  lazy (Error.invalid_request read_only_escalation_reason)

let unconfined = { decision = Unconfined; escalation = Ignored }
let external_ = { decision = Declared_external; escalation = Ignored }

let confined ?backend policy =
  let backend =
    match backend with
    | Some backend -> backend
    | None -> Lazy.force default_backend
  in
  let escalation =
    match Confinement.writable_roots policy with
    | [] -> Denied (Lazy.force read_only_escalation_error)
    | _ :: _ -> Available
  in
  Log.debug (fun m ->
      m "sealing confinement backend=%s writable_roots=%d network=%s"
        (Backend.id backend)
        (List.length (Confinement.writable_roots policy))
        (network_name (Confinement.network_state policy)));
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
  { decision; escalation }

let spawn t ~argv:command_argv ~env:bindings =
  match t.decision with
  | Unconfined ->
      Ok
        Spawn.
          {
            argv = command_argv;
            env = bindings;
            evidence = Evidence.not_requested;
          }
  | Declared_external ->
      Ok
        Spawn.
          {
            argv = command_argv;
            env = bindings;
            evidence = Evidence.declared_external;
          }
  | Refuse error -> Error error
  | Confine { prepared; evidence = command_evidence } ->
      let filtered_env, stripped = Env.partition bindings in
      let wrapped_argv = Backend.wrap prepared ~argv:command_argv in
      Log.debug (fun m ->
          m "confined spawn program=%s stripped %d env var(s)%s"
            (Argv.program command_argv)
            (List.length stripped)
            (match stripped with
            | [] -> ""
            | names -> ": " ^ String.concat ", " names));
      Ok
        Spawn.
          {
            argv = wrapped_argv;
            env = filtered_env;
            evidence = command_evidence;
          }

let escalation t = t.escalation

let evidence t =
  match t.decision with
  | Unconfined -> Evidence.not_requested
  | Declared_external -> Evidence.declared_external
  | Confine { evidence; _ } -> evidence
  | Refuse error -> Evidence.refused error
