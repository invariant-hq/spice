(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Account = Spice_host.Account
module Auth = Spice_auth
module Llm_provider = Spice_llm.Provider
module Provider = Spice_provider
module Protocol = Spice_provider.Auth.Login.Protocol

type event =
  | Browser_url of Uri.t
  | Listening of { redirect_uri : Uri.t }
  | Device_challenge of { url : Uri.t; user_code : string; expires_in : int }

type settled =
  | Checked of Spice_account.t
  | Unchecked of { account : Spice_account.t option; reason : string }
  | Failed of string
  | Cancelled

type logout = { env_still_active : string option }

let timestamp stdenv =
  Eio.Stdenv.clock stdenv |> Eio.Time.now |> Float.floor |> Int64.of_float

let callback_timeout_s = 300.0

let headless_hint message =
  message ^ "; on a remote or headless machine, use a device-code login"

(* {2 Endpoint rerooting}

   A [SPICE_<PROVIDER>_AUTH_BASE_URL] override reroots every protocol endpoint
   onto the override's scheme, host, and port; identity in production. *)

let reroot_uri ~root uri =
  Uri.with_scheme uri (Uri.scheme root) |> fun uri ->
  Uri.with_host uri (Uri.host root) |> fun uri ->
  Uri.with_port uri (Uri.port root)

let reroot_protocol ~root = function
  | Protocol.Api_key -> Protocol.Api_key
  | Protocol.OAuth2_device_code spec ->
      Protocol.OAuth2_device_code
        {
          spec with
          Protocol.device_endpoint =
            reroot_uri ~root spec.Protocol.device_endpoint;
          device_token_endpoint =
            reroot_uri ~root spec.Protocol.device_token_endpoint;
        }
  | Protocol.OAuth2_authorization_code spec ->
      Protocol.OAuth2_authorization_code
        {
          spec with
          Protocol.authorization_endpoint =
            reroot_uri ~root spec.Protocol.authorization_endpoint;
          authorization_token_endpoint =
            reroot_uri ~root spec.Protocol.authorization_token_endpoint;
        }
  | Protocol.Provider_device_code _ as protocol -> protocol
  | Protocol.External _ as protocol -> protocol

let resolve_protocol host ~provider ~method_id =
  match Spice_host.Host.require_provider host provider with
  | Error _ -> Error ("unknown provider: " ^ Llm_provider.id provider)
  | Ok decl -> (
      match Provider.Auth.login_by_id (Provider.auth decl) method_id with
      | None -> Error ("unknown auth method: " ^ method_id)
      | Some login -> (
          let protocol = Provider.Auth.Login.protocol login in
          match Account.provider_auth_base_url host ~provider with
          | None -> Ok protocol
          | Some root ->
              Ok (reroot_protocol ~root:(Uri.of_string root) protocol)))

(* {2 Settling}

   Every flow settles through one policy: persist, then check with one
   provider request; a check that cannot run degrades to the passive account
   view. *)

let save ~stdenv host ~provider ?name secret =
  match Account.Store.save ~stdenv ~host ~provider ?name secret with
  | Error error -> Failed (Account.Error.message error)
  | Ok () -> (
      match Account.load ~stdenv host with
      | Error error ->
          Unchecked { account = None; reason = Account.Error.message error }
      | Ok accounts -> (
          let checked =
            Eio.Switch.run @@ fun sw ->
            Account.check ~sw ~stdenv ~now:(timestamp stdenv) ?name accounts
              provider
          in
          match checked with
          | Ok account -> Checked account
          | Error error -> (
              let reason = Spice_host.Host.Error.message error in
              match Account.status accounts ?name provider with
              | Ok account -> Unchecked { account = Some account; reason }
              | Error _ -> Unchecked { account = None; reason })))

(* [race ?cancel body] runs [body], preempted by [cancel]: the first to settle
   wins, and a resolved [cancel] returns [`Cancelled] immediately. *)
let race ?cancel body =
  match cancel with
  | None -> body ()
  | Some cancel ->
      Eio.Fiber.first
        (fun () ->
          Eio.Promise.await cancel;
          `Cancelled)
        body

let browser ~stdenv host ~provider ~method_id ?name ?cancel events =
  match resolve_protocol host ~provider ~method_id with
  | Error message -> Failed message
  | Ok (Protocol.OAuth2_authorization_code spec) -> (
      Mirage_crypto_rng_unix.use_default ();
      let random n = Mirage_crypto_rng.generate n in
      match Auth.OAuth2_authorization_code.start ~random spec with
      | Error error -> Failed (Auth.Error.message error)
      | Ok started -> (
          let authorization_uri =
            Auth.OAuth2_authorization_code.authorization_uri started
          in
          let redirect_uri =
            Auth.OAuth2_authorization_code.redirect_uri started
          in
          events (Browser_url authorization_uri);
          let awaited =
            race ?cancel (fun () ->
                let on_ready () = events (Listening { redirect_uri }) in
                `Callback
                  (Auth.Local_callback.await_once ~stdenv ~on_ready
                     ~redirect_uri ~timeout_s:callback_timeout_s ()))
          in
          match awaited with
          | `Cancelled -> Cancelled
          | `Callback (Error error) ->
              let message =
                match error with
                | Auth.Error.Timeout _ | Auth.Error.Network _ ->
                    headless_hint (Auth.Error.message error)
                | Auth.Error.Invalid_secret _ | Auth.Error.Invalid_request _
                | Auth.Error.Protocol _ | Auth.Error.Rejected _
                | Auth.Error.Not_refreshable ->
                    Auth.Error.message error
              in
              Failed message
          | `Callback (Ok callback) -> (
              let secret =
                Eio.Switch.run @@ fun sw ->
                match Auth.Http.tls_client ~stdenv with
                | Error error -> Error error
                | Ok http ->
                    let profile =
                      if Llm_provider.equal provider Spice_llm_openai.provider
                      then Auth.OAuth2_authorization_code.Openai_chatgpt
                      else Auth.OAuth2_authorization_code.Generic
                    in
                    Auth.OAuth2_authorization_code.complete_secret ~http ~sw
                      started ~callback ~now:(timestamp stdenv) ~profile
              in
              match secret with
              | Error error -> Failed (Auth.Error.message error)
              | Ok secret -> save ~stdenv host ~provider ?name secret)))
  | Ok
      ( Protocol.Api_key | Protocol.OAuth2_device_code _
      | Protocol.Provider_device_code _ | Protocol.External _ ) ->
      Failed "this provider has no browser login"

(* One challenge dispatch and poll loop drives both device flows; the protocol
   arms differ only in how they obtain the initial authorization state. *)
let drive_device ~stdenv host ~provider ?name ?cancel ~events ~http ~sw started
    =
  let challenge = Auth.Device_code.challenge started in
  events
    (Device_challenge
       {
         url = challenge.Auth.Device_code.verification_uri;
         user_code = challenge.Auth.Device_code.user_code;
         expires_in = max 0 (Auth.Device_code.expires_in started);
       });
  let settled =
    race ?cancel (fun () ->
        let rec poll authorization =
          let delay =
            Auth.Device_code.next_poll_delay_s ~now:(timestamp stdenv)
              authorization
          in
          if delay > 0 then
            Eio.Time.sleep (Eio.Stdenv.clock stdenv) (Float.of_int delay);
          match
            Auth.Device_code.poll ~http ~sw ~now:(timestamp stdenv)
              authorization
          with
          | Error error -> Failed (Auth.Error.message error)
          | Ok (Auth.Device_code.Authorized secret) ->
              save ~stdenv host ~provider ?name secret
          | Ok (Auth.Device_code.Pending authorization) -> poll authorization
          | Ok (Auth.Device_code.Expired authorization) ->
              Failed
                (Printf.sprintf "device-code authorization expired at %Ld"
                   (Auth.Device_code.expires_at authorization))
          | Ok (Auth.Device_code.Rejected error) ->
              Failed (Auth.Error.message error)
        in
        `Settled (poll started))
  in
  match settled with `Cancelled -> Cancelled | `Settled settled -> settled

let openai_chatgpt_config host ~provider =
  match Account.provider_auth_base_url host ~provider with
  | None -> Ok Auth.Openai_chatgpt.Config.default
  | Some root ->
      Result.map_error Auth.Error.message
        (Auth.Openai_chatgpt.Config.make ~issuer:(Uri.of_string root) ())

let device ~stdenv host ~provider ~method_id ?name ?cancel events =
  match resolve_protocol host ~provider ~method_id with
  | Error message -> Failed message
  | Ok protocol -> (
      let start ~http ~sw =
        match protocol with
        | Protocol.OAuth2_device_code spec ->
            Ok
              (Auth.Device_code.start_oauth2 ~http ~sw ~now:(timestamp stdenv)
                 spec)
        | Protocol.Provider_device_code { provider_flow = "openai_chatgpt" }
          -> (
            match openai_chatgpt_config host ~provider with
            | Error message -> Error message
            | Ok config ->
                Ok
                  (Auth.Device_code.start_openai_chatgpt ~http ~sw
                     ~now:(timestamp stdenv) config))
        | Protocol.Provider_device_code { provider_flow } ->
            Error
              (Printf.sprintf "unknown provider login flow %S" provider_flow)
        | Protocol.Api_key | Protocol.OAuth2_authorization_code _
        | Protocol.External _ ->
            Error "this provider has no device-code login"
      in
      Eio.Switch.run @@ fun sw ->
      match Auth.Http.tls_client ~stdenv with
      | Error error -> Failed (Auth.Error.message error)
      | Ok http -> (
          match start ~http ~sw with
          | Error message -> Failed message
          | Ok (Error error) -> Failed (Auth.Error.message error)
          | Ok (Ok started) ->
              drive_device ~stdenv host ~provider ?name ?cancel ~events ~http
                ~sw started))

let logout ~stdenv host ~provider ?name () =
  match Account.Store.remove ~stdenv ~host ~provider ?name () with
  | Error error -> Error (Account.Error.message error)
  | Ok () ->
      let env_still_active =
        match Account.load ~stdenv host with
        | Error _ -> None
        | Ok accounts -> (
            match Account.credential accounts ?name provider with
            | Ok (Some credential) -> (
                match Spice_account.Credential.source credential with
                | Spice_account.Credential.Source.Env env_name -> Some env_name
                | Spice_account.Credential.Source.Process
                | Spice_account.Credential.Source.Store _ ->
                    None)
            | Ok None | Error _ -> None)
      in
      Ok { env_still_active }

let open_browser uri =
  let uri = Uri.to_string uri in
  match Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 with
  | exception Unix.Unix_error _ -> false
  | null ->
      Fun.protect
        ~finally:(fun () -> Unix.close null)
        (fun () ->
          let rec run = function
            | [] -> false
            | (program, argv) :: rest -> (
                match Unix.create_process program argv null null null with
                | _pid -> true
                | exception Unix.Unix_error _ -> run rest)
          in
          if String.equal Sys.os_type "Win32" then
            run [ ("cmd", [| "cmd"; "/c"; "start"; ""; uri |]) ]
          else
            run
              [
                ("open", [| "open"; uri |]); ("xdg-open", [| "xdg-open"; uri |]);
              ])
