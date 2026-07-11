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

exception Cancel_after_remote
exception Route_failure

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
      ~run:(fun ~cancelled:_ ~on_event _ ->
        Llm.Stream.iter_events
          (Llm.Stream.of_list [ Llm.Stream.Finished terminal ])
          ~f:on_event)
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
              Llm.Client.response client (request ()))
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
      | Ok _response -> ()
      | Error error -> failf "response: %a" Llm.Error.pp error)
    attempts;
  equal int ~msg:"concurrent first responses prepare once" 1 !starts

(* Same-process lock admission and post-I/O cancellation are scheduler seams,
   so these contracts use injected routes and promises; the black-box auth
   cases cover the corresponding cross-process user workflows. *)

let credential_refresh_lock_is_single_flight_and_cancellable () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-refresh-lock-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-refresh-lock-state" );
      ]
  in
  let entered, entered_resolver = Eio.Promise.create () in
  let release, release_resolver = Eio.Promise.create () in
  let starts = ref 0 in
  let refresh ~sw:_ ~stdenv:_ ~now:_ ?auth_base_url:_ _secret =
    incr starts;
    ignore (Eio.Promise.try_resolve entered_resolver ());
    Eio.Promise.await release;
    Ok
      (Account.Secret.oauth ~access_token:"access-token-new"
         ~refresh_token:"refresh-token-new" ~expires_at:10_000L ())
  in
  let adapter =
    Host.Adapter.make
      ~build:(fun ~sw:_ ~stdenv:_ ?base_url:_ _ -> failwith "unused build")
      ~refresh ()
  in
  let registry =
    ok "refresh registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  let refreshable =
    Account.Secret.oauth ~access_token:"access-token-old"
      ~refresh_token:"refresh-token-old" ~expires_at:10_000L ()
  in
  Spice_host.Account.Store.save ~stdenv ~host ~provider:openai refreshable
  |> account_ok "save refreshable credential";
  let load_expected () =
    let accounts =
      Spice_host.Account.load ~stdenv host |> account_ok "load account"
    in
    let credential =
      Spice_host.Account.credential accounts openai
      |> account_ok "resolve credential"
      |> Option.get
    in
    (accounts, credential)
  in
  let first_accounts, first_credential = load_expected () in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Spice_host.Account.refresh ~sw ~stdenv ~now:100L ~force:true
          first_accounts first_credential)
  in
  Eio.Promise.await entered;
  let waiting_accounts, waiting_credential = load_expected () in
  let cancel, cancel_resolver = Eio.Promise.create () in
  let attempted, attempted_resolver = Eio.Promise.create () in
  let waiting =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Promise.resolve attempted_resolver ();
        Eio.Fiber.first
          (fun () ->
            ignore
              (Spice_host.Account.refresh ~sw ~stdenv ~now:100L ~force:true
                 waiting_accounts waiting_credential);
            `Completed)
          (fun () ->
            Eio.Promise.await cancel;
            `Cancelled))
  in
  Eio.Promise.await attempted;
  Eio.Fiber.yield ();
  equal int ~msg:"same slot admits one refresh route" 1 !starts;
  Eio.Promise.resolve cancel_resolver ();
  let cancelled =
    Eio.Time.with_timeout (Eio.Stdenv.clock stdenv) 0.5 (fun () ->
        Ok (Eio.Promise.await_exn waiting))
  in
  (match cancelled with
  | Ok `Cancelled -> ()
  | Ok `Completed -> failf "cancelled lock waiter entered the refresh route"
  | Error `Timeout ->
      ignore (Eio.Promise.try_resolve release_resolver ());
      failf "cancelled lock waiter did not settle");
  let second_accounts, second_credential = load_expected () in
  let second =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Spice_host.Account.refresh ~sw ~stdenv ~now:100L ~force:true
          second_accounts second_credential)
  in
  Eio.Fiber.yield ();
  equal int ~msg:"same slot remains single-flight while pending" 1 !starts;
  Eio.Promise.resolve release_resolver ();
  Eio.Promise.await_exn first |> ok "first refresh" |> Option.get |> ignore;
  Eio.Promise.await_exn second |> ok "second refresh" |> Option.get |> ignore;
  equal int ~msg:"waiter reuses the committed rotation" 1 !starts

let concurrent_auth_failures_refresh_the_serving_credential () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-serving-credential-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-serving-credential-state" );
      ]
  in
  let original =
    Account.Secret.oauth ~access_token:"serving-access-old"
      ~refresh_token:"serving-refresh-old" ~expires_at:Int64.max_int ()
  in
  let replacement =
    Account.Secret.oauth ~access_token:"serving-access-new"
      ~refresh_token:"serving-refresh-new" ~expires_at:Int64.max_int ()
  in
  let refresh_entered, refresh_entered_resolver = Eio.Promise.create () in
  let allow_refresh, allow_refresh_resolver = Eio.Promise.create () in
  let second_failed, second_failed_resolver = Eio.Promise.create () in
  let allow_second_failure, allow_second_failure_resolver =
    Eio.Promise.create ()
  in
  let refresh_starts = ref 0 in
  let refresh ~sw:_ ~stdenv:_ ~now:_ ?auth_base_url:_ _secret =
    incr refresh_starts;
    ignore (Eio.Promise.try_resolve refresh_entered_resolver ());
    Eio.Promise.await allow_refresh;
    Ok replacement
  in
  let terminal =
    Llm.Response.make ~model (Llm.Message.Assistant.text "Recovered.")
  in
  let success_client =
    Llm.Client.make ~provider:openai
      ~run:(fun ~cancelled:_ ~on_event _ ->
        Llm.Stream.iter_events
          (Llm.Stream.of_list [ Llm.Stream.Finished terminal ])
          ~f:on_event)
      ()
  in
  let old_calls = ref 0 in
  let old_client =
    Llm.Client.make ~provider:openai
      ~run:(fun ~cancelled:_ ~on_event:_ _ ->
        incr old_calls;
        if !old_calls = 2 then (
          Eio.Promise.resolve second_failed_resolver ();
          Eio.Promise.await allow_second_failure);
        Error
          (Llm.Error.make ~kind:Llm.Error.Auth ~provider:openai
             "access token rejected"))
      ()
  in
  let build ~sw:_ ~stdenv:_ ?base_url:_ = function
    | Some credential
      when Account.Secret.equal (Credential.secret credential) original ->
        Ok old_client
    | Some _ -> Ok success_client
    | None -> failwith "missing serving credential"
  in
  let adapter = Host.Adapter.make ~build ~refresh () in
  let registry =
    ok "serving-credential registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  Spice_host.Account.Store.save ~stdenv ~host ~provider:openai original
  |> account_ok "save serving credential";
  let client =
    Spice_host.client ~sw ~stdenv host (Provider.Model.make model ())
    |> ok "build serving client"
  in
  let first =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Llm.Client.response client (request ()))
  in
  Eio.Promise.await refresh_entered;
  let second =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Llm.Client.response client (request ()))
  in
  Eio.Promise.await second_failed;
  Eio.Promise.resolve allow_refresh_resolver ();
  (match Eio.Promise.await_exn first with
  | Ok _ -> ()
  | Error error -> failf "first recovery: %a" Llm.Error.pp error);
  Eio.Promise.resolve allow_second_failure_resolver ();
  (match Eio.Promise.await_exn second with
  | Ok _ -> ()
  | Error error -> failf "second recovery: %a" Llm.Error.pp error);
  equal int ~msg:"both failures refresh their shared serving credential once" 1
    !refresh_starts

let remote_settlement_survives_cancellation () =
  Eio_main.run @@ fun stdenv ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-cancel-settlement-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-cancel-settlement-state" );
      ]
  in
  let original =
    Account.Secret.oauth ~access_token:"cancel-access-old"
      ~refresh_token:"cancel-refresh-old" ~expires_at:1L ()
  in
  let replacement =
    Account.Secret.oauth ~access_token:"cancel-access-new"
      ~refresh_token:"cancel-refresh-new" ~expires_at:10_000L ()
  in
  let refresh ~sw ~stdenv:_ ~now:_ ?auth_base_url:_ _secret =
    Eio.Switch.fail sw Cancel_after_remote;
    Ok replacement
  in
  let revoke ~sw ~stdenv:_ ?auth_base_url:_ _secret =
    Eio.Switch.fail sw Cancel_after_remote;
    Ok ()
  in
  let adapter =
    Host.Adapter.make
      ~build:(fun ~sw:_ ~stdenv:_ ?base_url:_ _ -> failwith "unused build")
      ~refresh ~revoke ()
  in
  let registry =
    ok "cancel-settlement registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  let save secret =
    Spice_host.Account.Store.save ~stdenv ~host ~provider:openai secret
    |> account_ok "save cancellation credential"
  in
  let load () =
    let accounts =
      Spice_host.Account.load ~stdenv host
      |> account_ok "load cancellation account"
    in
    let credential =
      Spice_host.Account.credential accounts openai
      |> account_ok "resolve cancellation credential"
    in
    (accounts, credential)
  in
  let expect_cancelled f =
    match Eio.Switch.run f with
    | _ -> failf "cancelled remote operation returned normally"
    | exception Cancel_after_remote -> ()
    | exception Eio.Cancel.Cancelled _ -> ()
  in
  save original;
  let accounts, credential = load () in
  let credential = Option.get credential in
  expect_cancelled (fun request_sw ->
      Spice_host.Account.refresh ~sw:request_sw ~stdenv ~now:100L accounts
        credential
      |> ignore);
  let _, refreshed = load () in
  let refreshed = Option.get refreshed |> Credential.secret in
  is_true ~msg:"successful remote refresh commits before cancellation escapes"
    (Account.Secret.equal replacement refreshed);
  save original;
  expect_cancelled (fun request_sw ->
      Spice_host.Account.revoke ~sw:request_sw ~stdenv ~host ~provider:openai ()
      |> ignore);
  let _, revoked = load () in
  equal bool ~msg:"completed remote revoke removes before cancellation escapes"
    true (Option.is_none revoked)

let provider_route_exceptions_propagate () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-route-exception-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-route-exception-state" );
      ]
  in
  let refresh ~sw:_ ~stdenv:_ ~now:_ ?auth_base_url:_ _secret =
    raise Route_failure
  in
  let adapter =
    Host.Adapter.make
      ~build:(fun ~sw:_ ~stdenv:_ ?base_url:_ _ -> failwith "unused build")
      ~refresh ()
  in
  let registry =
    ok "route-exception registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  let secret =
    Account.Secret.oauth ~access_token:"route-exception-access"
      ~refresh_token:"route-exception-refresh" ~expires_at:1L ()
  in
  Spice_host.Account.Store.save ~stdenv ~host ~provider:openai secret
  |> account_ok "save route-exception credential";
  let accounts =
    Spice_host.Account.load ~stdenv host
    |> account_ok "load route-exception account"
  in
  let credential =
    Spice_host.Account.credential accounts openai
    |> account_ok "resolve route-exception credential"
    |> Option.get
  in
  match
    Spice_host.Account.refresh ~sw ~stdenv ~now:100L accounts credential
  with
  | _ -> failf "provider route exception became a result"
  | exception Route_failure -> ()

let cross_process_refresh_lock_wait_is_cancellable () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let cwd = Sys.getcwd () in
  let process_env =
    Env.of_list
      [
        ( "SPICE_CONFIG_HOME",
          Filename.concat cwd "_build/test-host-process-lock-config" );
        ( "SPICE_STATE_HOME",
          Filename.concat cwd "_build/test-host-process-lock-state" );
      ]
  in
  let refresh ~sw:_ ~stdenv:_ ~now:_ ?auth_base_url:_ _secret =
    failwith "cross-process lock waiter reached the refresh route"
  in
  let adapter =
    Host.Adapter.make
      ~build:(fun ~sw:_ ~stdenv:_ ?base_url:_ _ -> failwith "unused build")
      ~refresh ()
  in
  let registry =
    ok "process-lock registry"
      (Host.Provider_registry.make
         [ Host.Provider.make provider_decl ~adapter () ])
  in
  let host = host ~registry ~stdenv ~process_env () in
  let refreshable =
    Account.Secret.oauth ~access_token:"process-lock-access"
      ~refresh_token:"process-lock-refresh" ~expires_at:10_000L ()
  in
  Spice_host.Account.Store.save ~stdenv ~host ~provider:openai refreshable
  |> account_ok "save process-lock credential";
  let accounts =
    Spice_host.Account.load ~stdenv host
    |> account_ok "load process-lock account"
  in
  let credential =
    Spice_host.Account.credential accounts openai
    |> account_ok "resolve process-lock credential"
    |> Option.get
  in
  let auth_path =
    Spice_host.Host.config host
    |> Config.auth_store_path |> Spice_path.Abs.to_string
  in
  let slot =
    Spice_digest.key ~length:64 ~domain:"spice.host.account.credential-lock.v1"
      [ Llm.Provider.id openai; "default" ]
  in
  let lock_path = auth_path ^ ".credential-" ^ slot ^ ".lock" in
  let ready_path = lock_path ^ ".ready" in
  let release_path = lock_path ^ ".release" in
  let remove path = try Unix.unlink path with Unix.Unix_error _ -> () in
  remove ready_path;
  remove release_path;
  let helper =
    let from_cwd = Filename.concat cwd "bin/account_lock_holder.exe" in
    if Sys.file_exists from_cwd then from_cwd
    else
      Filename.concat
        (Filename.dirname Sys.executable_name)
        "bin/account_lock_holder.exe"
  in
  let pid =
    Unix.create_process helper
      [| helper; lock_path; ready_path; release_path |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let touch path =
    let channel = open_out_bin path in
    close_out channel
  in
  let rec await_process () =
    match Unix.waitpid [] pid with
    | _ -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> await_process ()
  in
  Fun.protect
    ~finally:(fun () ->
      touch release_path;
      await_process ();
      remove ready_path;
      remove release_path)
    (fun () ->
      let rec await_ready attempts =
        if Sys.file_exists ready_path then ()
        else if attempts = 0 then failf "lock holder did not become ready"
        else (
          Eio.Time.sleep (Eio.Stdenv.clock stdenv) 0.01;
          await_ready (attempts - 1))
      in
      await_ready 200;
      (match
         Eio.Time.with_timeout (Eio.Stdenv.clock stdenv) 0.5 (fun () ->
             Ok
               (Spice_host.Account.refresh ~sw ~stdenv ~now:100L accounts
                  credential))
       with
      | Ok result -> result |> ok "fresh refresh fast path" |> ignore
      | Error `Timeout -> failf "fresh credential waited for the slot lock");
      let cancel, cancel_resolver = Eio.Promise.create () in
      let attempted, attempted_resolver = Eio.Promise.create () in
      let waiting =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Promise.resolve attempted_resolver ();
            Eio.Fiber.first
              (fun () ->
                ignore
                  (Spice_host.Account.refresh ~sw ~stdenv ~now:100L ~force:true
                     accounts credential);
                `Completed)
              (fun () ->
                Eio.Promise.await cancel;
                `Cancelled))
      in
      Eio.Promise.await attempted;
      Eio.Fiber.yield ();
      Eio.Promise.resolve cancel_resolver ();
      match
        Eio.Time.with_timeout (Eio.Stdenv.clock stdenv) 0.5 (fun () ->
            Ok (Eio.Promise.await_exn waiting))
      with
      | Ok `Cancelled -> ()
      | Ok `Completed -> failf "cross-process lock waiter entered refresh"
      | Error `Timeout -> failf "cross-process lock cancellation did not settle")

let () =
  run "spice.host.account"
    [
      test "process credentials shadow environment"
        process_credentials_shadow_environment;
      test "model artifact preparation is single-flight"
        model_artifact_preparation_is_single_flight;
      test "credential refresh lock is single-flight and cancellable"
        credential_refresh_lock_is_single_flight_and_cancellable;
      test "concurrent auth failures refresh their serving credential"
        concurrent_auth_failures_refresh_the_serving_credential;
      test "remote settlement survives cancellation"
        remote_settlement_survives_cancellation;
      test "provider route exceptions propagate"
        provider_route_exceptions_propagate;
      test "cross-process refresh lock wait is cancellable"
        cross_process_refresh_lock_wait_is_cancellable;
    ]
