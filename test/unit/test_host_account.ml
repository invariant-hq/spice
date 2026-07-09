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

let host ~stdenv ~process_env =
  let cwd = Sys.getcwd () in
  let store_root = "_build/test-host-account-store" in
  let config =
    match Config.load ~stdenv ~process_env ~cwd ~store_root () with
    | Ok config -> config
    | Error error -> failf "config: %a" Config.Error.pp error
  in
  ok "host" (Host.make ~config ~registry ())

let process_credentials_shadow_environment () =
  Eio_main.run @@ fun stdenv ->
  let config_home =
    Filename.concat (Sys.getcwd ()) "_build/test-host-account-config"
  in
  let process_env =
    Env.of_list
      [
        ("SPICE_CONFIG_HOME", config_home);
        ("OPENAI_API_KEY", "env-key-material");
      ]
  in
  let host = host ~stdenv ~process_env in
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

let () =
  run "spice.host.account"
    [
      test "process credentials shadow environment"
        process_credentials_shadow_environment;
    ]
