(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Account = Spice_account
module Credential = Account.Credential
module Config = Spice_host.Config
module Env = Spice_host.Env
module Host = Spice_host.Host
module Llm = Spice_llm
module Provider = Spice_provider
module Source = Credential.Source

let openai = Llm.Provider.make "openai"
let api = Llm.Model.Api.make "responses"
let model = Llm.Model.make ~provider:openai ~api ~id:"gpt-test"
let source_value = testable ~pp:Source.pp ~equal:Source.equal ()

let ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Host.Error.pp error

let account_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Spice_host.Account.Error.pp error

let provider_decl =
  let auth =
    Provider.Auth.make
      ~env:[ Provider.Auth.Env.api_key "OPENAI_API_KEY" ]
      ~login:[ Provider.Auth.Login.api_key () ]
      ()
  in
  Provider.make openai ~auth [ Provider.Model.make model () ]

let registry =
  ok "registry"
    (Host.Provider_registry.make [ Host.Provider.make provider_decl () ])

let host ?(registry = registry) ~stdenv ~process_env () =
  let cwd = Sys.getcwd () in
  let data_home = "_build/test-host-account-store" in
  let config =
    match Config.load ~stdenv ~process_env ~cwd ~data_home () with
    | Ok config -> config
    | Error error -> failf "config: %a" Config.Error.pp error
  in
  ok "host" (Host.make ~config ~registry ())

let request () =
  let transcript =
    match Llm.Transcript.of_list [ Llm.Message.user_text "Run." ] with
    | Ok transcript -> transcript
    | Error error ->
        failf "transcript: %a" Llm.Transcript.Error.pp error
  in
  match Llm.Request.make ~model transcript with
  | Ok request -> request
  | Error error -> failf "request: %a" Llm.Request.Error.pp error

let process_credentials_shadow_environment () =
  Eio_main.run @@ fun stdenv ->
  let config_home =
    Filename.concat (Sys.getcwd ()) "_build/test-host-account-config"
  in
  let process_env =
    Env.of_list
      [
        ("SPICE_CONFIG_HOME", config_home);
        ( "SPICE_STATE_HOME",
          Filename.concat (Sys.getcwd ()) "_build/test-host-account-state" );
        ("OPENAI_API_KEY", "env-key-material");
      ]
  in
  let host = host ~stdenv ~process_env () in
  let process =
    [
      Credential.make ~provider:openai ~source:Source.process
        (Account.Secret.api_key "process-key-material");
    ]
  in
  let accounts =
    Spice_host.Account.load ~stdenv ~process host |> account_ok "account load"
  in
  let credential =
    Spice_host.Account.credential accounts openai |> account_ok "credential"
  in
  equal (option source_value) ~msg:"process source wins" (Some Source.process)
    (Option.map Credential.source credential)

let model_artifact_preparation_is_single_flight () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-artifact-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-artifact-state" );
      ]
  in
  let entered, entered_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let starts = ref 0 in
  let prepare ~sw:_ ~stdenv:_ ~cancelled:_ ~observe:_ _model =
    incr starts;
    ignore (Eio.Promise.try_resolve entered_resolver ());
    Eio.Promise.await release;
    Ok ()
  in
  let terminal =
    Llm.Response.make ~model (Llm.Message.Assistant.text "Done.")
  in
  let client =
    Llm.Client.make ~provider:openai
      ~run:(fun ~cancelled:_ _ ->
        Ok (Llm.Stream.of_list [ Llm.Stream.Finished terminal ]))
      ()
  in
  let adapter =
    Host.Adapter.make
      ~build:(fun ~sw:_ ~stdenv:_ ?base_url:_ _credential -> Ok client)
      ~model_artifact:
        Host.Adapter.{
          status = (fun _ -> None);
          prepare;
          download =
            (fun ~sw:_ ~stdenv:_ ~force:_ ~observe:_ _ ->
              failwith "unused model artifact download");
        }
      ()
  in
  let registry =
    ok "artifact registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  let provider_model = Provider.Model.make model () in
  let client =
    match Spice_host.client ~sw ~stdenv host provider_model with
    | Ok client -> client
    | Error error -> failf "client: %a" Host.Error.pp error
  in
  let start, start_resolver = Eio.Promise.create () in
  let attempts =
    List.init 2 (fun _ ->
        let attempted, attempted_resolver = Eio.Promise.create () in
        let result =
          Eio.Fiber.fork_promise ~sw (fun () ->
              Eio.Promise.await start;
              Eio.Promise.resolve attempted_resolver ();
              Llm.Client.stream client (request ()))
        in
        (attempted, result))
  in
  Eio.Promise.resolve start_resolver ();
  List.iter (fun (attempted, _) -> Eio.Promise.await attempted) attempts;
  Eio.Promise.await entered;
  Eio.Fiber.yield ();
  Eio.Promise.resolve release_resolver ();
  List.iter
    (fun (_, result) ->
      match Eio.Promise.await_exn result with
      | Ok _stream -> ()
      | Error error -> failf "stream: %a" Llm.Error.pp error)
    attempts;
  equal int ~msg:"concurrent first streams prepare once" 1 !starts

let () =
  run "spice.host.account"
    [
      test "process credentials shadow environment"
        process_credentials_shadow_environment;
      test "model artifact preparation is single-flight"
        model_artifact_preparation_is_single_flight;
    ]
