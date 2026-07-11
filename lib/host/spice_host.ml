(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Env = Env
module Config = Config
module User_dirs = User_dirs
module Workspace_state = Workspace_state
module Trust = Trust
module Host = Host
module Account = Account
module Models = Models
module Reason = Reason
module Permission = Permission
module Sandbox = Sandbox
module Turn_options = Turn_options
module Context = Context
module Skills = Skills
module Notice_queue = Notice_queue
module Compactor = Compactor
module Mutations = Mutations
module Artifacts = Artifacts
module Handler = Handler
module Goal_run = Goal_run
module Session = Session
module Runner = Runner
module Live = Live
module Toolset = Toolset
module Jobs = Jobs
module Run = Run

let ( let* ) = Result.bind

let bootstrap ~stdenv ~registry ?cwd ?(overrides = []) () =
  let process_env = Env.current () in
  let* config =
    Config.load ~stdenv ~process_env ?cwd ~overrides ()
    |> Result.map_error (fun error -> Host.Error.Config error)
  in
  Host.load ~stdenv ~registry ~config ()

let timestamp_now stdenv =
  Eio.Stdenv.clock stdenv |> Eio.Time.now |> Float.floor |> Int64.of_float

let provider_error_of_host ~provider error =
  Spice_llm.Error.make ~kind:Spice_llm.Error.Auth ~provider
    (Spice_diagnostic.to_string (Host.Error.diagnostic error))

let with_refresh_retry ~rebuild ~refresh credential client =
  let provider = Spice_llm.Client.provider client in
  let current = ref (client, credential) in
  let run ~cancelled ~on_event request =
    let client, credential = !current in
    match Spice_llm.Client.response ~cancelled ~on_event client request with
    | Error error as result -> (
        match (Spice_llm.Error.kind error, Spice_llm.Error.phase error) with
        | Spice_llm.Error.Auth, Spice_llm.Error.Startup -> (
            match refresh credential with
            | Ok (Some credential) -> (
                match rebuild credential with
                | Ok client ->
                    current := (client, credential);
                    Spice_llm.Client.response ~cancelled ~on_event client
                      request
                | Error error -> Error (provider_error_of_host ~provider error))
            | Error error -> Error (provider_error_of_host ~provider error)
            | Ok None -> result)
        | _ -> result)
    | result -> result
  in
  Spice_llm.Client.make ~provider ~run ()

let with_model_artifact_prepare ~sw ~stdenv ?observe_model_artifact adapter
    model client =
  match Host.Adapter.model_artifact adapter with
  | None -> client
  | Some { Host.Adapter.prepare; _ } ->
      let prepared = ref false in
      let preparing = Eio.Mutex.create () in
      let observe =
        Option.value observe_model_artifact ~default:(fun _progress -> ())
      in
      let run ~cancelled ~on_event request =
        let preparation =
          if !prepared then Ok ()
          else
            Eio.Mutex.use_ro preparing (fun () ->
                if !prepared then Ok ()
                else
                  match prepare ~sw ~stdenv ~cancelled ~observe model with
                  | Error _ as error -> error
                  | Ok () ->
                      prepared := true;
                      Ok ())
        in
        match preparation with
        | Error _ as error -> error
        | Ok () -> Spice_llm.Client.response ~cancelled ~on_event client request
      in
      Spice_llm.Client.make ~provider:(Spice_llm.Client.provider client) ~run ()

(* Whether a missing credential is an error is the adapter's answer, not a
   host-side gate: a mandatory-auth adapter returns [Missing_credential] on
   [None] itself, and an optional-auth adapter builds a bare client. *)
let client ~sw ~stdenv ?observe_model_artifact ?name ?process host model =
  let provider = Spice_provider.Model.provider model in
  let map_account_error result =
    Result.map_error (Account.Error.to_host host) result
  in
  let* account = Account.load ~stdenv ?process host |> map_account_error in
  let* resolved =
    Account.credential account ?name provider |> map_account_error
  in
  match resolved with
  | None -> (
      match Host.adapter host provider with
      | None -> Error (Host.Error.No_adapter provider)
      | Some adapter ->
          let base_url =
            Config.Models.provider_base_url
              (Config.models (Host.config host))
              ~provider
          in
          Host.Adapter.build adapter ~sw ~stdenv ?base_url None
          |> Result.map
               (with_model_artifact_prepare ~sw ~stdenv ?observe_model_artifact
                  adapter model))
  | Some credential -> (
      match Host.adapter host provider with
      | None -> Error (Host.Error.No_adapter provider)
      | Some adapter -> (
          let base_url =
            Config.Models.provider_base_url
              (Config.models (Host.config host))
              ~provider
          in
          let build credential =
            Host.Adapter.build adapter ~sw ~stdenv ?base_url (Some credential)
            |> Result.map
                 (with_model_artifact_prepare ~sw ~stdenv
                    ?observe_model_artifact adapter model)
          in
          let* refreshed =
            Account.refresh ~sw ~stdenv ~now:(timestamp_now stdenv) account
              credential
          in
          match refreshed with
          | None ->
              Host.Adapter.build adapter ~sw ~stdenv ?base_url None
              |> Result.map
                   (with_model_artifact_prepare ~sw ~stdenv
                      ?observe_model_artifact adapter model)
          | Some credential -> (
              let* client = build credential in
              match
                ( Host.Adapter.refresh adapter,
                  Spice_account.Credential.kind credential )
              with
              | Some _, Spice_account.Secret.Kind.OAuth ->
                  let refresh credential =
                    Account.refresh ~sw ~stdenv ~now:(timestamp_now stdenv)
                      ~force:true account credential
                  in
                  Ok
                    (with_refresh_retry ~rebuild:build ~refresh credential
                       client)
              | ( Some _,
                  ( Spice_account.Secret.Kind.Api_key
                  | Spice_account.Secret.Kind.Bearer ) )
              | None, _ ->
                  Ok client)))

let model_artifact_status host model =
  let provider = Spice_provider.Model.provider model in
  match Host.adapter host provider with
  | None -> None
  | Some adapter -> (
      match Host.Adapter.model_artifact adapter with
      | None -> None
      | Some artifact -> artifact.Host.Adapter.status model)

let download_model_artifact host ~sw ~stdenv ?observe ~force model =
  let provider = Spice_provider.Model.provider model in
  match Host.adapter host provider with
  | None -> None
  | Some adapter -> (
      match Host.Adapter.model_artifact adapter with
      | None -> None
      | Some artifact ->
          let observe = Option.value observe ~default:(fun _progress -> ()) in
          Some
            (artifact.Host.Adapter.download ~sw ~stdenv ~force ~observe model))

let workspace host =
  let root = Config.cwd (Host.config host) in
  Ok (Spice_workspace.single (Spice_workspace.Root.make root))

let default_ignore = Watchers.Fswatch.default_ignore
