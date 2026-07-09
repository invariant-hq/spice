(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Adapter = Spice_host.Host.Adapter
module Credential = Spice_account.Credential
module Problem = Spice_account.Problem
module Secret = Spice_account.Secret

module Check = struct
  let problem ~status ~body =
    if status = 401 || status = 403 then Problem.Invalid_credential
    else if status = 402 then Problem.Quota_exceeded
    else if status = 429 then
      if String.includes ~affix:"quota" (String.lowercase_ascii body) then
        Problem.Quota_exceeded
      else Problem.Rate_limited
    else if status >= 500 then Problem.Network
    else Problem.other "unknown_provider_response"

  let json_field name = function
    | Jsont.Object (fields, _) ->
        Option.map snd (Jsont.Json.find_mem name fields)
    | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
    | Jsont.Array _ ->
        None

  let json_string_field name json =
    match json_field name json with
    | Some (Jsont.String (value, _)) -> Some value
    | Some _ | None -> None

  let entry_ids ~id values =
    let ids = List.filter_map (json_string_field id) values in
    if List.length ids = List.length values then Some ids else None

  let models body =
    match Jsont_bytesrw.decode_string Jsont.json body with
    | Error _ -> None
    | Ok json -> (
        match json_field "data" json with
        | Some (Jsont.Array (values, _)) -> entry_ids ~id:"id" values
        | Some _ -> None
        | None -> (
            match json_field "models" json with
            | Some (Jsont.Array (values, _)) ->
                entry_ids ~id:"name" values
                |> Option.map
                     (List.map (fun value ->
                          let prefix = "models/" in
                          if String.starts_with ~prefix value then
                            String.drop_first (String.length prefix) value
                          else value))
            | Some _ | None -> None))
end

let max_check_body_size = 1_048_576
let check_timeout_s = 10.0

let https ~authenticator =
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Error (`Msg message) -> failwith ("TLS configuration error: " ^ message)
    | Ok config -> config
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun value -> Domain_name.(host_exn (of_string_exn value)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

(* Seeding the default RNG and decoding the system trust store are both needed
   before the first TLS handshake, neither is needed to assemble a client, and
   both are costly — seeding reads OS entropy, the authenticator decodes the
   whole CA bundle (tens of milliseconds each). Deferring them to the first
   handshake through [Lazy] keeps that cost off the boot and prewarm paths (the
   home frame renders without waiting on entropy or X.509 decoding) and pays it
   once for every TLS consumer, replacing the per-client re-decode. *)
let tls_authenticator =
  lazy
    (Mirage_crypto_rng_unix.use_default ();
     match Ca_certs.authenticator () with
     | Ok authenticator -> authenticator
     | Error (`Msg message) -> failwith ("X509 authenticator: " ^ message))

let cohttp_headers headers =
  List.fold_left
    (fun acc (name, value) -> Cohttp.Header.add acc name value)
    (Cohttp.Header.init ()) headers

let read_body body =
  let chunk = Cstruct.create 4096 in
  let buffer = Buffer.create 1024 in
  let rec loop remaining =
    if remaining > 0 then
      match Eio.Flow.single_read body chunk with
      | exception End_of_file -> ()
      | count ->
          let count = min count remaining in
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop (remaining - count)
  in
  loop max_check_body_size;
  Buffer.contents buffer

let http_get ~sw ~stdenv ~headers url =
  try
    let client =
      Cohttp_eio.Client.make
        ~https:
          (Some
             (fun uri raw ->
               https ~authenticator:(Lazy.force tls_authenticator) uri raw))
        (Eio.Stdenv.net stdenv)
    in
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock stdenv) check_timeout_s
      (fun () ->
        let response, body =
          Cohttp_eio.Client.call client ~sw ~headers:(cohttp_headers headers)
            `GET (Uri.of_string url)
        in
        let status =
          Cohttp.Code.code_of_status (Cohttp.Response.status response)
        in
        Ok (status, read_body body))
  with _ -> Error ()

let observation ?(problems = []) ?models () =
  { Adapter.problems; profile = None; org = None; models }

let unsupported_route = observation ~problems:[ Problem.Unsupported ] ()
let network_problem = observation ~problems:[ Problem.Network ] ()

let observe ~sw ~stdenv ~headers url =
  match http_get ~sw ~stdenv ~headers url with
  | Error () -> network_problem
  | Ok (status, body) ->
      if status >= 200 && status < 300 then
        match Check.models body with
        | Some models -> observation ~models ()
        | None ->
            observation
              ~problems:[ Problem.other "unknown_provider_response" ]
              ()
      else observation ~problems:[ Check.problem ~status ~body ] ()

let effective_base_url ~default = function
  | None -> default
  | Some base_url -> base_url

let web_http_client stdenv =
  Cohttp_eio.Client.make
    ~https:
      (Some
         (fun uri raw ->
           https ~authenticator:(Lazy.force tls_authenticator) uri raw))
    (Eio.Stdenv.net stdenv)

let web_fetch_https () =
 fun uri raw ->
  (https ~authenticator:(Lazy.force tls_authenticator) uri raw
    :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r)

let chatgpt_base_url = "https://chatgpt.com/backend-api/codex"

let chatgpt_account_headers = function
  | None -> []
  | Some account_id -> [ ("chatgpt-account-id", account_id) ]

let openai_auth_config = function
  | None -> Ok Spice_auth.Openai_chatgpt.Config.default
  | Some issuer ->
      Spice_auth.Openai_chatgpt.Config.make ~issuer:(Uri.of_string issuer) ()

let openai_auth_problem = function
  | Spice_auth.Error.Rejected _ -> Spice_account.Problem.Refresh_failed
  | Spice_auth.Error.Network _ | Spice_auth.Error.Timeout _ ->
      Spice_account.Problem.Network
  | Spice_auth.Error.Protocol _ ->
      Spice_account.Problem.other "unknown_provider_response"
  | Spice_auth.Error.Not_refreshable | Spice_auth.Error.Invalid_secret _
  | Spice_auth.Error.Invalid_request _ ->
      Spice_account.Problem.Unsupported

let with_openai_auth ~stdenv ?auth_base_url run =
  match openai_auth_config auth_base_url with
  | Error error -> Error (openai_auth_problem error)
  | Ok config -> (
      match Spice_auth.Http.tls_client ~stdenv with
      | Error _ -> Error Spice_account.Problem.Network
      | Ok http -> (
          match run http config with
          | Ok _ as ok -> ok
          | Error error -> Error (openai_auth_problem error)))

let openai_refresh ~sw ~stdenv ~now ?auth_base_url secret =
  with_openai_auth ~stdenv ?auth_base_url (fun http config ->
      Spice_auth.Openai_chatgpt.refresh ~http ~sw ~now config secret)

let openai_revoke ~sw ~stdenv ?auth_base_url secret =
  with_openai_auth ~stdenv ?auth_base_url (fun http config ->
      Spice_auth.Openai_chatgpt.revoke ~http ~sw config secret)

let openai_check ~sw ~stdenv ?base_url credential =
  let models ~default ~headers =
    observe ~sw ~stdenv ~headers
      (effective_base_url ~default base_url ^ "/models")
  in
  let api_route token =
    models ~default:"https://api.openai.com/v1"
      ~headers:[ ("authorization", "Bearer " ^ token) ]
  in
  Secret.expose
    (Credential.secret credential)
    ~api_key:(fun ~key -> Ok (api_route key))
    ~bearer:(fun ~token -> Ok (api_route token))
    ~oauth:(fun ~access_token ~refresh_token:_ ~expires_at:_ ~account_id ->
      Ok
        (models ~default:chatgpt_base_url
           ~headers:
             (("authorization", "Bearer " ^ access_token)
             :: chatgpt_account_headers account_id)))

let anthropic_headers secret =
  Secret.expose secret
    ~api_key:(fun ~key ->
      Some [ ("x-api-key", key); ("anthropic-version", "2023-06-01") ])
    ~bearer:(fun ~token ->
      Some
        [
          ("authorization", "Bearer " ^ token);
          ("anthropic-version", "2023-06-01");
        ])
    ~oauth:(fun ~access_token:_ ~refresh_token:_ ~expires_at:_ ~account_id:_ ->
      None)

let anthropic_check ~sw ~stdenv ?base_url credential =
  match anthropic_headers (Credential.secret credential) with
  | None -> Ok unsupported_route
  | Some headers ->
      let base_url =
        effective_base_url ~default:"https://api.anthropic.com/v1" base_url
      in
      Ok (observe ~sw ~stdenv ~headers (base_url ^ "/models"))

let google_key secret =
  Secret.expose secret
    ~api_key:(fun ~key -> Some key)
    ~bearer:(fun ~token:_ -> None)
    ~oauth:(fun ~access_token:_ ~refresh_token:_ ~expires_at:_ ~account_id:_ ->
      None)

let google_check ~sw ~stdenv ?base_url credential =
  match google_key (Credential.secret credential) with
  | None -> Ok unsupported_route
  | Some key ->
      let base_url =
        effective_base_url
          ~default:"https://generativelanguage.googleapis.com/v1beta" base_url
      in
      let url =
        Uri.of_string (base_url ^ "/models")
        |> (fun uri -> Uri.add_query_param' uri ("key", key))
        |> Uri.to_string
      in
      Ok (observe ~sw ~stdenv ~headers:[] url)

let openai_adapter =
  Adapter.make ~check:openai_check ~refresh:openai_refresh ~revoke:openai_revoke
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      match credential with
      | None ->
          Error
            (Spice_host.Host.Error.Missing_credential Spice_llm_openai.provider)
      | Some credential ->
          let api_route credential =
            let config = Spice_llm_openai.Config.make ?base_url () in
            Ok (Spice_llm_openai.client ~sw ~env:stdenv ~config ~credential ())
          in
          Secret.expose
            (Credential.secret credential)
            ~api_key:(fun ~key ->
              api_route (Spice_llm_openai.Credential.api_key key))
            ~bearer:(fun ~token ->
              api_route (Spice_llm_openai.Credential.bearer token))
            ~oauth:(fun
                ~access_token ~refresh_token:_ ~expires_at:_ ~account_id ->
              let base_url =
                effective_base_url ~default:chatgpt_base_url base_url
              in
              let config =
                Spice_llm_openai.Config.make ~base_url
                  ~headers:(chatgpt_account_headers account_id)
                  ()
              in
              Ok
                (Spice_llm_openai.client ~sw ~env:stdenv ~config
                   ~credential:(Spice_llm_openai.Credential.bearer access_token)
                   ())))
    ()

let openai =
  Spice_host.Host.Provider.make Spice_provider_builtin.openai
    ~adapter:openai_adapter ()

let anthropic_adapter =
  Adapter.make ~check:anthropic_check
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      match credential with
      | None ->
          Error
            (Spice_host.Host.Error.Missing_credential
               Spice_llm_anthropic.provider)
      | Some credential -> (
          (* No Anthropic OAuth flow exists: an OAuth secret here would ride as
             a static bearer that nothing refreshes, and the check already
             reports OAuth unsupported — the build agrees rather than sending a
             token that silently goes stale. *)
          let credential =
            Secret.expose
              (Credential.secret credential)
              ~api_key:(fun ~key ->
                Ok (Spice_llm_anthropic.Credential.api_key key))
              ~bearer:(fun ~token ->
                Ok (Spice_llm_anthropic.Credential.bearer token))
              ~oauth:(fun
                  ~access_token:_
                  ~refresh_token:_
                  ~expires_at:_
                  ~account_id:_
                ->
                Error
                  (Spice_host.Host.Error.Unsupported_credential
                     {
                       provider = Spice_llm_anthropic.provider;
                       kind = Secret.Kind.OAuth;
                     }))
          in
          match credential with
          | Error _ as error -> error
          | Ok credential ->
              let config = Spice_llm_anthropic.Config.make ?base_url () in
              Ok
                (Spice_llm_anthropic.client ~sw ~env:stdenv ~config ~credential
                   ())))
    ()

let anthropic =
  Spice_host.Host.Provider.make Spice_provider_builtin.anthropic
    ~adapter:anthropic_adapter ()

let google_adapter =
  Adapter.make ~check:google_check
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      match credential with
      | None ->
          Error
            (Spice_host.Host.Error.Missing_credential Spice_llm_google.provider)
      | Some credential -> (
          let unsupported kind =
            Error
              (Spice_host.Host.Error.Unsupported_credential
                 { provider = Spice_llm_google.provider; kind })
          in
          let credential =
            Secret.expose
              (Credential.secret credential)
              ~api_key:(fun ~key ->
                Ok (Spice_llm_google.Credential.api_key key))
              ~bearer:(fun ~token:_ -> unsupported Secret.Kind.Bearer)
              ~oauth:(fun
                  ~access_token:_
                  ~refresh_token:_
                  ~expires_at:_
                  ~account_id:_
                -> unsupported Secret.Kind.OAuth)
          in
          match credential with
          | Error _ as error -> error
          | Ok credential ->
              let config = Spice_llm_google.Config.make ?base_url () in
              Ok
                (Spice_llm_google.client ~sw ~env:stdenv ~config ~credential ())
          ))
    ()

let google =
  Spice_host.Host.Provider.make Spice_provider_builtin.google
    ~adapter:google_adapter ()

let deepseek_adapter =
  let status model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    match Spice_llm_deepseek.Artifact.status id with
    | Error message ->
        Some (Spice_protocol.Model_artifact.Unavailable { message })
    | Ok (Spice_llm_deepseek.Artifact.Installed { path }) ->
        Some (Spice_protocol.Model_artifact.Installed { path })
    | Ok (Spice_llm_deepseek.Artifact.Missing { path; url; size }) ->
        Some
          (Spice_protocol.Model_artifact.Missing
             { path; size = Some size; source = Some url })
    | Ok (Spice_llm_deepseek.Artifact.Explicit_path { exists = true; path }) ->
        Some (Spice_protocol.Model_artifact.Installed { path })
    | Ok (Spice_llm_deepseek.Artifact.Explicit_path { exists = false; path }) ->
        Some
          (Spice_protocol.Model_artifact.Missing
             { path; size = None; source = None })
  in
  let observe_download observe (progress : Spice_llm_deepseek.Download.progress)
      =
    let phase =
      match progress.Spice_llm_deepseek.Download.phase with
      | Spice_llm_deepseek.Download.Checking ->
          Spice_protocol.Model_artifact.Checking
      | Spice_llm_deepseek.Download.Downloading ->
          Spice_protocol.Model_artifact.Downloading
      | Spice_llm_deepseek.Download.Verifying ->
          Spice_protocol.Model_artifact.Verifying
      (* Provider [Installed] (download complete) is the neutral [Ready] phase;
         the enum rename is intentional. *)
      | Spice_llm_deepseek.Download.Installed ->
          Spice_protocol.Model_artifact.Ready
    in
    observe
      {
        Spice_protocol.Model_artifact.provider = Spice_llm_deepseek.provider;
        model = progress.Spice_llm_deepseek.Download.model;
        label = progress.Spice_llm_deepseek.Download.label;
        path = progress.Spice_llm_deepseek.Download.path;
        received = progress.Spice_llm_deepseek.Download.received;
        total = progress.Spice_llm_deepseek.Download.total;
        phase;
      }
  in
  let prepare ~sw ~stdenv ~cancelled ~observe model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    Spice_llm_deepseek.Artifact.prepare ~sw ~env:stdenv
      ~http:(web_http_client stdenv) ~cancelled
      ~observe_download:(observe_download observe) id
  in
  let download ~sw ~stdenv ~force:_ ~observe model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    match Spice_llm_deepseek.Artifact.status id with
    | Error message ->
        Spice_protocol.Model_artifact.Refused { message; force_hint = false }
    | Ok (Spice_llm_deepseek.Artifact.Installed { path }) ->
        Spice_protocol.Model_artifact.Already_installed path
    | Ok (Spice_llm_deepseek.Artifact.Explicit_path _) ->
        Spice_protocol.Model_artifact.Not_downloadable
    | Ok (Spice_llm_deepseek.Artifact.Missing _) -> (
        match
          Spice_llm_deepseek.Artifact.prepare ~sw ~env:stdenv
            ~http:(web_http_client stdenv)
            ~cancelled:(fun () -> false)
            ~observe_download:(observe_download observe) id
        with
        | Ok () -> Spice_protocol.Model_artifact.Downloaded
        (* DeepSeek has no download guard, so no failure is force-recoverable. *)
        | Error error ->
            Spice_protocol.Model_artifact.Refused
              { message = Spice_llm.Error.message error; force_hint = false })
  in
  let model_artifact = { Adapter.status; prepare; download } in
  Adapter.make
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      match base_url with
      | Some base_url ->
          Error
            (Spice_host.Host.Error.Client
               {
                 provider = Spice_llm_deepseek.provider;
                 message =
                   Printf.sprintf
                     "base URL override %S is not supported for local DeepSeek"
                     base_url;
               })
      | None -> (
          match credential with
          | None ->
              Ok
                (Spice_llm_deepseek.client ~sw ~env:stdenv
                   ~http:(web_http_client stdenv) ())
          | Some credential ->
              Error
                (Spice_host.Host.Error.Unsupported_credential
                   {
                     provider = Spice_llm_deepseek.provider;
                     kind = Credential.kind credential;
                   })))
    ~model_artifact ()

let deepseek =
  Spice_host.Host.Provider.make Spice_provider_builtin.deepseek
    ~adapter:deepseek_adapter ()

let local_adapter =
  let status model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    match Spice_llm_local.Artifact.status id with
    | Error message ->
        Some (Spice_protocol.Model_artifact.Unavailable { message })
    | Ok (Spice_llm_local.Artifact.Installed { path }) ->
        Some (Spice_protocol.Model_artifact.Installed { path })
    | Ok (Spice_llm_local.Artifact.Missing { path; url; size }) ->
        Some
          (Spice_protocol.Model_artifact.Missing
             { path; size = Some size; source = Some url })
    | Ok (Spice_llm_local.Artifact.Explicit_path { exists = true; path }) ->
        Some (Spice_protocol.Model_artifact.Installed { path })
    | Ok (Spice_llm_local.Artifact.Explicit_path { exists = false; path }) ->
        Some
          (Spice_protocol.Model_artifact.Missing
             { path; size = None; source = None })
  in
  let observe_download observe (progress : Spice_llm_local.Download.progress) =
    let phase =
      match progress.Spice_llm_local.Download.phase with
      | Spice_llm_local.Download.Checking ->
          Spice_protocol.Model_artifact.Checking
      | Spice_llm_local.Download.Downloading ->
          Spice_protocol.Model_artifact.Downloading
      | Spice_llm_local.Download.Verifying ->
          Spice_protocol.Model_artifact.Verifying
      (* Provider [Installed] (download complete) is the neutral [Ready] phase;
         the enum rename is intentional. *)
      | Spice_llm_local.Download.Installed ->
          Spice_protocol.Model_artifact.Ready
    in
    observe
      {
        Spice_protocol.Model_artifact.provider = Spice_llm_local.provider;
        model = progress.Spice_llm_local.Download.model;
        label = progress.Spice_llm_local.Download.label;
        path = progress.Spice_llm_local.Download.path;
        received = progress.Spice_llm_local.Download.received;
        total = progress.Spice_llm_local.Download.total;
        phase;
      }
  in
  let prepare ~sw ~stdenv ~cancelled ~observe model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    Spice_llm_local.Artifact.prepare ~sw ~env:stdenv
      ~http:(web_http_client stdenv) ~cancelled
      ~observe_download:(observe_download observe) id
  in
  let download ~sw ~stdenv ~force ~observe model =
    let id = Spice_llm.Model.id (Spice_provider.Model.llm model) in
    match Spice_llm_local.Artifact.status id with
    | Error message ->
        Spice_protocol.Model_artifact.Refused { message; force_hint = false }
    | Ok (Spice_llm_local.Artifact.Installed { path }) ->
        Spice_protocol.Model_artifact.Already_installed path
    | Ok (Spice_llm_local.Artifact.Explicit_path _) ->
        Spice_protocol.Model_artifact.Not_downloadable
    | Ok (Spice_llm_local.Artifact.Missing _) -> (
        match
          Spice_llm_local.Artifact.prepare ~sw ~env:stdenv
            ~http:(web_http_client stdenv)
            ~cancelled:(fun () -> false)
            ~observe_download:(observe_download observe) ~force id
        with
        | Ok () -> Spice_protocol.Model_artifact.Downloaded
        | Error error ->
            (* The memory-budget guard is the only [Unsupported] failure on
               this path; transport and verification failures are [Provider]. A
               force override overrides the guard alone, so hint it only for a
               guard refusal that was not already forced. *)
            let force_hint =
              match Spice_llm.Error.kind error with
              | Spice_llm.Error.Unsupported -> not force
              | _ -> false
            in
            Spice_protocol.Model_artifact.Refused
              { message = Spice_llm.Error.message error; force_hint })
  in
  let model_artifact = { Adapter.status; prepare; download } in
  Adapter.make
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      match base_url with
      | Some base_url ->
          Error
            (Spice_host.Host.Error.Client
               {
                 provider = Spice_llm_local.provider;
                 message =
                   Printf.sprintf
                     "base URL override %S is not supported for managed local \
                      models"
                     base_url;
               })
      | None -> (
          match credential with
          | None ->
              Ok
                (Spice_llm_local.client ~sw ~env:stdenv
                   ~http:(web_http_client stdenv) ())
          | Some credential ->
              Error
                (Spice_host.Host.Error.Unsupported_credential
                   {
                     provider = Spice_llm_local.provider;
                     kind = Credential.kind credential;
                   })))
    ~model_artifact ()

let local =
  Spice_host.Host.Provider.make Spice_provider_builtin.local
    ~adapter:local_adapter ()

let ollama_adapter =
  Adapter.make
    ~build:(fun ~sw ~stdenv ?base_url credential ->
      let config =
        match base_url with
        | None -> Ok Spice_llm_ollama.Config.default
        | Some base_url -> (
            match Spice_llm_ollama.Config.make ~base_url () with
            | config -> Ok config
            | exception Invalid_argument message ->
                Error
                  (Spice_host.Host.Error.Client
                     { provider = Spice_llm_ollama.provider; message }))
      in
      (* Auth is optional (the declaration says so): no credential builds a
         bare client for the default localhost daemon; a stored or env one
         rides every request as a bearer header for key-protected
         deployments. OAuth material has no Ollama meaning and is refused. *)
      let credential =
        match credential with
        | None -> Ok None
        | Some credential ->
            Secret.expose
              (Credential.secret credential)
              ~api_key:(fun ~key ->
                Ok (Some (Spice_llm_ollama.Credential.api_key key)))
              ~bearer:(fun ~token ->
                Ok (Some (Spice_llm_ollama.Credential.bearer token)))
              ~oauth:(fun
                  ~access_token:_
                  ~refresh_token:_
                  ~expires_at:_
                  ~account_id:_
                ->
                Error
                  (Spice_host.Host.Error.Unsupported_credential
                     {
                       provider = Spice_llm_ollama.provider;
                       kind = Secret.Kind.OAuth;
                     }))
      in
      match (config, credential) with
      | (Error _ as error), _ | _, (Error _ as error) -> error
      | Ok config, Ok credential ->
          Ok (Spice_llm_ollama.client ~sw ~env:stdenv ~config ?credential ()))
    ()

let ollama =
  Spice_host.Host.Provider.make Spice_provider_builtin.ollama
    ~adapter:ollama_adapter ()

let all = [ openai; anthropic; google; deepseek; local; ollama ]

let registry =
  match Spice_host.Host.Provider_registry.make all with
  | Ok registry -> registry
  | Error error ->
      invalid_arg
        ("Spice_host_builtin.registry: " ^ Spice_host.Host.Error.message error)

module Login = Login
