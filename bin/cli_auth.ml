(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module CArg = Cmdliner.Arg
module CTerm = Cmdliner.Term
module CCmd = Cmdliner.Cmd
module CManpage = Cmdliner.Manpage
open Cli_common
module Account = Spice_host.Account
module Auth = Spice_auth
module Credential = Spice_account.Credential
module Model_choice = Spice_host.Models.Model_choice
module Llm_provider = Spice_llm.Provider
module Provider = Spice_provider
module Provider_auth = Spice_provider.Auth

type status_row = {
  provider : Provider.t;
  account : Spice_account.t;
  store_names : Credential.Name.t list;
  selected_model : (string * string) option;
      (* canonical selector and provider-local model id of the resolved main
         model, when it belongs to this row's provider *)
}

type provider_filter = {
  positional : Llm_provider.t option;
  option : Llm_provider.t option;
}

let login_method_of_string raw =
  if String.is_empty raw then Error (`Msg "auth method must not be empty")
  else Ok raw

let pp_login_method = Format.pp_print_string
let login_method = CArg.conv (login_method_of_string, pp_login_method)
let provider_filter positional option = { positional; option }

let selected_provider filter =
  match (filter.positional, filter.option) with
  | None, None -> Ok None
  | Some provider, None | None, Some provider -> Ok (Some provider)
  | Some positional, Some option ->
      if Llm_provider.equal positional option then Ok (Some positional)
      else
        Error
          (Printf.sprintf
             "provider specified twice with different values: %s and %s"
             (Llm_provider.id positional)
             (Llm_provider.id option))

let host_error_message error =
  Spice_diagnostic.to_string (Spice_host.Host.Error.diagnostic error)

let kind_route_label = function
  | Spice_account.Secret.Kind.Api_key -> "api-key"
  | Spice_account.Secret.Kind.Bearer -> "bearer"
  | Spice_account.Secret.Kind.OAuth -> "oauth"

let iso8601 seconds =
  let tm = Unix.gmtime (Int64.to_float seconds) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let json_null_or_int64 = function
  | None -> json_null
  | Some value -> Jsont.Json.int64 value

let row_account row = row.account

let provider_requires_auth provider =
  Provider.Auth.required (Provider.auth provider)

(* A missing credential only demands repair where auth is required: a no-auth
   or optional-auth provider serves bare, so its missing account reads ready.
   A stored credential on an optional-auth provider keeps its real phase — a
   blocked key is worth reporting even where none was mandatory. *)
let row_phase row =
  match Spice_account.phase row.account with
  | `Missing when not (provider_requires_auth row.provider) -> `Ready
  | phase -> phase

let row_phase_string row = Spice_account.phase_to_string (row_phase row)
let row_provider_id row = Llm_provider.id (Provider.id row.provider)

let row_route row =
  Spice_account.credential_kind (row_account row)
  |> Option.map (fun kind -> row_provider_id row ^ "/" ^ kind_route_label kind)

let row_fingerprint row = Spice_account.fingerprint row.account

let row_transient row =
  match Spice_account.problems (row_account row) with
  | [] -> false
  | problems -> List.for_all Spice_account.Problem.transient problems

let row_repair row =
  match row_phase row with
  | `Missing | `Blocked ->
      Some (Printf.sprintf "spice auth login %s" (row_provider_id row))
  | `Unchecked ->
      Some
        (Printf.sprintf "spice auth status %s --refresh" (row_provider_id row))
  | `Degraded ->
      if row_transient row then
        Some
          (Printf.sprintf "spice auth status %s --refresh" (row_provider_id row))
      else None
  | `Ready -> None

let selected_model_json row (selector, model_id) =
  json_obj
    [
      ("selector", Jsont.Json.string selector);
      ( "available",
        match Spice_account.model_available row.account model_id with
        | `Available -> Jsont.Json.bool true
        | `Unavailable -> Jsont.Json.bool false
        | `Unknown -> json_null );
    ]

let provider_json row =
  let account = row_account row in
  let source =
    Option.map account_source_string (Spice_account.source account)
  in
  let source_name =
    Option.bind
      (Spice_account.source account)
      Spice_account.Credential.Source.name
  in
  json_obj
    ([
       ("provider", Jsont.Json.string (row_provider_id row));
       ("route", json_null_or_string (row_route row));
       ("source", json_null_or_string source);
       ("source_name", json_null_or_string source_name);
       ("fingerprint", json_null_or_string (row_fingerprint row));
       ( "env",
         Provider.auth row.provider |> Provider.Auth.env
         |> List.map (fun env -> Jsont.Json.string (Provider.Auth.Env.name env))
         |> json_list );
       ( "store_names",
         row.store_names
         |> List.map (fun name ->
             Jsont.Json.string (Credential.Name.to_string name))
         |> json_list );
       ("phase", Jsont.Json.string (row_phase_string row));
       ("checked_at", json_null_or_int64 (Spice_account.checked_at account));
       ( "problems",
         Spice_account.problems account
         |> List.map (fun problem ->
             Jsont.Json.string (Spice_account.Problem.to_string problem))
         |> json_list );
       ("transient", Jsont.Json.bool (row_transient row));
       ("repair", json_null_or_string (row_repair row));
     ]
    @
    match row.selected_model with
    | None -> []
    | Some selected -> [ ("selected_model", selected_model_json row selected) ]
    )

let selected_model_for ~connected host provider =
  match Spice_host.Models.choose ~connected host Model_choice.Main with
  | Error _ -> None
  | Ok choice ->
      let model = Model_choice.model choice in
      if Llm_provider.equal (Provider.Model.provider model) provider then
        Some (Provider.Model.selector model, Provider.Model.id model)
      else None

let find_provider_decl host provider =
  match Spice_host.Host.require_provider host provider with
  | Error (`Unknown_provider provider) ->
      Error ("unknown provider: " ^ Llm_provider.id provider)
  | Ok provider -> Ok provider

let find_provider host provider =
  match find_provider_decl host provider with
  | Error _ as error -> error
  | Ok provider -> Ok (Provider.id provider)

let stored_name = function None -> Credential.Name.default | Some name -> name
let stored_name_string name = Credential.Name.to_string (stored_name name)

let timestamp_now stdenv =
  Eio.Stdenv.clock stdenv |> Eio.Time.now |> Float.floor |> Int64.of_float

let read_stdin_secret () =
  let text = In_channel.input_all stdin in
  let rec trim_newlines text =
    let len = String.length text in
    if
      len > 0
      && (Char.equal text.[len - 1] '\n' || Char.equal text.[len - 1] '\r')
    then trim_newlines (String.sub text 0 (len - 1))
    else text
  in
  trim_newlines text

let api_key_pipe_example ~command provider_decl =
  let env_name =
    match Provider.auth provider_decl |> Provider.Auth.env with
    | env :: _ -> Provider.Auth.Env.name env
    | [] -> "API_KEY"
  in
  Printf.sprintf "printenv %s | spice auth %s" env_name command

(* Read a secret at the terminal with echo disabled, restoring the terminal
   attributes even if the read is interrupted. The user's enter is not echoed,
   so the newline is printed back once the attributes are restored. *)
let read_tty_secret ~prompt =
  stdout_printf "%s" prompt;
  let attrs = Unix.tcgetattr Unix.stdin in
  Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH { attrs with Unix.c_echo = false };
  Fun.protect
    ~finally:(fun () ->
      Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH attrs;
      stdout_printf "\n")
    (fun () -> try input_line stdin with End_of_file -> "")

(* An API key arrives one of two ways: piped through [--api-key-stdin] (the
   scriptable path), or typed at a no-echo terminal prompt when stdin is an
   interactive terminal. A non-TTY stdin without the flag keeps the explicit
   demand, so a script never blocks on a silent read. *)
let read_api_key ~command ~example ~prompt ~api_key_stdin =
  let secret raw =
    match Auth.Secret.api_key raw with
    | Error error -> Error (Auth.Error.message error)
    | Ok secret -> Ok secret
  in
  if api_key_stdin then
    if Unix.isatty Unix.stdin then
      Error
        (Printf.sprintf
           "--api-key-stdin expects the API key on stdin; try piping it: %s"
           example)
    else secret (read_stdin_secret ())
  else if Unix.isatty Unix.stdin then secret (read_tty_secret ~prompt)
  else Error ("auth " ^ command ^ " requires --api-key-stdin")

(* Render a settled login: the header lines, the checked/unchecked account
   facts, and the suggested next command. Every flow settles through
   {!Spice_host_builtin.Login}'s persist-then-check policy, so browser and
   device logins print the same block the api-key login always has. *)
let print_login_settled host ~provider_decl ~name ~method_id settled =
  let provider = Provider.id provider_decl in
  let provider_id = Llm_provider.id provider in
  let print_header () =
    let auth_store_path =
      Spice_host.Host.config host
      |> Spice_host.Config.auth_store_path |> Spice_path.Abs.to_string
    in
    stdout_printf "Logged in to %s with %s.\n" provider_id method_id;
    stdout_printf "Saved:   %s (file store %s)\n" (stored_name_string name)
      auth_store_path
  in
  match settled with
  | Spice_host_builtin.Login.Cancelled -> Runtime_error "login cancelled"
  | Spice_host_builtin.Login.Failed message -> Runtime_error message
  | Spice_host_builtin.Login.Unchecked { account = _; reason } ->
      print_header ();
      stdout_printf "Checked: unchecked\n";
      stdout_printf "Next:    spice auth status %s --refresh\n" provider_id;
      stderr_printf "spice: warning: %s\n" reason;
      Success
  | Spice_host_builtin.Login.Checked account -> (
      print_header ();
      let problems () =
        Spice_account.problems account
        |> List.map Spice_account.Problem.to_string
        |> String.concat ", "
      in
      let phase = Spice_account.phase account in
      (match phase with
      | `Ready -> (
          match Spice_account.checked_at account with
          | Some at ->
              stdout_printf "Checked: ready (validated %s)\n" (iso8601 at)
          | None -> stdout_printf "Checked: ready\n")
      | `Degraded -> stdout_printf "Checked: degraded (%s)\n" (problems ())
      | `Blocked -> stdout_printf "Checked: blocked (%s)\n" (problems ())
      | `Unchecked | `Missing -> stdout_printf "Checked: unchecked\n");
      let next =
        match phase with
        | `Ready -> (
            match
              (* The provider in hand just logged in: it alone reads as
                 connected, so the freshly connected default wins exactly when
                 no configured selection names another provider. *)
              selected_model_for
                ~connected:(Llm_provider.equal provider)
                host provider
            with
            | Some (selector, _) ->
                Printf.sprintf "spice run --model %s \"...\"" selector
            | None -> "spice models current")
        | `Blocked -> Printf.sprintf "spice auth status %s" provider_id
        | `Degraded | `Unchecked | `Missing ->
            Printf.sprintf "spice auth status %s --refresh" provider_id
      in
      stdout_printf "Next:    %s\n" next;
      match phase with
      | `Blocked -> Failed
      | `Ready | `Degraded | `Unchecked | `Missing -> Success)

let api_key_prompt provider =
  Printf.sprintf "Enter your %s API key (input hidden): "
    (Llm_provider.id provider)

let login_api_key ~stdenv host ~provider_decl ~name ~method_id ~api_key_stdin =
  let provider = Provider.id provider_decl in
  let example =
    api_key_pipe_example provider_decl
      ~command:
        (Printf.sprintf "login %s --method %s --api-key-stdin"
           (Llm_provider.id provider) method_id)
  in
  match
    read_api_key ~command:"login --method api-key" ~example
      ~prompt:(api_key_prompt provider) ~api_key_stdin
  with
  | Error message -> Usage_error message
  | Ok secret ->
      print_login_settled host ~provider_decl ~name ~method_id
        (Spice_host_builtin.Login.save ~stdenv host ~provider ?name secret)

(* The terminal rendering of engine progress. The browser URL is remembered so
   {!Spice_host_builtin.Login.Listening} — the listener is bound — can open the
   browser at it, on a terminal only. *)
let print_login_events () =
  let browser_url = ref None in
  fun event ->
    match event with
    | Spice_host_builtin.Login.Browser_url uri ->
        browser_url := Some uri;
        stdout_printf "Go to: %s\n" (Uri.to_string uri)
    | Spice_host_builtin.Login.Listening { redirect_uri } ->
        stdout_printf "Listening for the browser callback on %s\n"
          (Uri.to_string redirect_uri);
        (match !browser_url with
        | Some uri when Unix.isatty Unix.stdout ->
            if not (Spice_host_builtin.Login.open_browser uri) then
              stdout_printf "Could not open browser automatically.\n"
        | Some _ | None -> ());
        stdout_printf "Waiting for authorization (300s timeout)...\n"
    | Spice_host_builtin.Login.Device_challenge
        { url; user_code; expires_in = _ } ->
        stdout_printf "Go to: %s\n" (Uri.to_string url);
        stdout_printf "Enter code: %s\n" user_code;
        stdout_printf
          "Device codes are a common phishing target. Never share this code.\n";
        stdout_printf "Waiting for authorization...\n"

type login_choice = Default | Api_key | Method of string

type login_error =
  | No_login_methods of Llm_provider.t
  | Unknown_method of { provider : Llm_provider.t; method_ : string }
  | No_api_key_method of Llm_provider.t

let login_error_message = function
  | No_login_methods provider ->
      "provider " ^ Llm_provider.id provider ^ " declares no login methods"
  | Unknown_method { provider; method_ } ->
      "unknown auth method \"" ^ method_ ^ "\" for provider "
      ^ Llm_provider.id provider
  | No_api_key_method provider ->
      "provider " ^ Llm_provider.id provider
      ^ " declares no API-key login method"

let is_api_key_login login =
  match Provider_auth.Login.protocol login with
  | Provider_auth.Login.Protocol.Api_key -> true
  | Provider_auth.Login.Protocol.OAuth2_device_code _
  | Provider_auth.Login.Protocol.OAuth2_authorization_code _
  | Provider_auth.Login.Protocol.Provider_device_code _
  | Provider_auth.Login.Protocol.External _ ->
      false

let choose_login ~provider_id choice auth =
  match choice with
  | Default -> (
      match Provider_auth.logins auth with
      | login :: _ -> Ok login
      | [] -> Error (No_login_methods provider_id))
  | Api_key -> (
      match List.find_opt is_api_key_login (Provider_auth.logins auth) with
      | Some login -> Ok login
      | None -> Error (No_api_key_method provider_id))
  | Method method_ -> (
      match Provider_auth.login_by_id auth method_ with
      | Some login -> Ok login
      | None -> Error (Unknown_method { provider = provider_id; method_ }))

let infer_login provider method_ api_key_stdin =
  let choice =
    match (method_, api_key_stdin) with
    | Some method_, _ -> Method method_
    | None, true -> Api_key
    | None, false -> Default
  in
  choose_login ~provider_id:(Provider.id provider) choice
    (Provider.auth provider)

let api_key_stdin_rejected login =
  Usage_error
    ("--api-key-stdin cannot be used with "
    ^ Provider_auth.Login.id login
    ^ " login")

let login provider name method_ api_key_stdin =
  with_host @@ fun ~stdenv host ->
  match find_provider_decl host provider with
  | Error message -> Usage_error message
  | Ok provider_decl -> (
      match infer_login provider_decl method_ api_key_stdin with
      | Error error ->
          let hints =
            match error with
            | Unknown_method { method_; _ } ->
                Spice_diagnostic.did_you_mean method_
                  ~candidates:
                    (Provider.auth provider_decl
                    |> Provider_auth.logins
                    |> List.map Provider_auth.Login.id)
            | No_login_methods _ | No_api_key_method _ -> []
          in
          Usage_error
            (Spice_diagnostic.to_string
               (Spice_diagnostic.make ~hints (login_error_message error)))
      | Ok login -> (
          let provider = Provider.id provider_decl in
          let method_id = Provider_auth.Login.id login in
          let default_choice = Option.is_none method_ && not api_key_stdin in
          let guard_tty run =
            if api_key_stdin then api_key_stdin_rejected login
            else if default_choice && not (Unix.isatty Unix.stdin) then
              Usage_error
                (Printf.sprintf
                   "auth login %s needs an explicit method without a terminal; \
                    use `--method device-code` or `--method api-key \
                    --api-key-stdin`"
                   (Llm_provider.id provider))
            else run ()
          in
          (* Dispatch on the declared protocol's shape; endpoint rerooting is
             the engine's concern. *)
          match Provider_auth.Login.protocol login with
          | Provider_auth.Login.Protocol.Api_key ->
              login_api_key ~stdenv host ~provider_decl ~name ~method_id
                ~api_key_stdin
          | Provider_auth.Login.Protocol.OAuth2_device_code _
          | Provider_auth.Login.Protocol.Provider_device_code
              { provider_flow = "openai_chatgpt" } ->
              guard_tty (fun () ->
                  print_login_settled host ~provider_decl ~name ~method_id
                    (Spice_host_builtin.Login.device ~stdenv host ~provider
                       ~method_id ?name (print_login_events ())))
          | Provider_auth.Login.Protocol.OAuth2_authorization_code _ ->
              guard_tty (fun () ->
                  print_login_settled host ~provider_decl ~name ~method_id
                    (Spice_host_builtin.Login.browser ~stdenv host ~provider
                       ~method_id ?name (print_login_events ())))
          | Provider_auth.Login.Protocol.Provider_device_code { provider_flow }
            ->
              Usage_error
                (Printf.sprintf "unknown provider login flow %S" provider_flow)
          | Provider_auth.Login.Protocol.External { instructions } ->
              Option.iter (stdout_printf "%s") instructions;
              Success))

let logout provider name revoke =
  with_host @@ fun ~stdenv host ->
  match find_provider_decl host provider with
  | Error message -> Usage_error message
  | Ok provider_decl -> (
      let provider = Provider.id provider_decl in
      let print_env_still_active = function
        | None -> ()
        | Some env_name ->
            stdout_printf
              "Environment credential %s is still active and cannot be removed \
               by Spice.\n"
              env_name
      in
      if not revoke then (
        match
          Spice_host_builtin.Login.logout ~stdenv host ~provider ?name ()
        with
        | Error message -> Runtime_error message
        | Ok { Spice_host_builtin.Login.env_still_active } ->
            stdout_printf "Removed %s credential %s\n"
              (Llm_provider.id provider) (stored_name_string name);
            print_env_still_active env_still_active;
            Success)
      else
        match
          Spice_host_builtin.Login.logout_revoke ~stdenv host ~provider ?name ()
        with
        | Error message -> Runtime_error message
        | Ok { Spice_host_builtin.Login.logout; revocation } ->
            let env_still_active =
              logout.Spice_host_builtin.Login.env_still_active
            in
            let local =
              match revocation with
              | Account.Revoke.Not_stored -> Account.Revoke.Removed
              | Account.Revoke.Settled { remote; local } ->
                  (match remote with
                  | Account.Revoke.Revoked ->
                      stdout_printf "Revoked %s credential\n"
                        (Llm_provider.id provider)
                  | Account.Revoke.Unsupported ->
                      stdout_printf
                        "The stored credential does not support provider \
                         revocation.\n"
                  | Account.Revoke.Failed problem -> (
                      let problem = Spice_account.Problem.to_string problem in
                      match local with
                      | Account.Revoke.Removed ->
                          stderr_printf
                            "spice: warning: revocation failed (%s); removing \
                             the local credential anyway\n"
                            problem
                      | Account.Revoke.Superseded ->
                          stderr_printf
                            "spice: warning: revocation failed (%s); keeping \
                             the replacement credential\n"
                            problem));
                  local
            in
            (match local with
            | Account.Revoke.Removed ->
                stdout_printf "Removed %s credential %s\n"
                  (Llm_provider.id provider) (stored_name_string name)
            | Account.Revoke.Superseded ->
                stdout_printf
                  "Kept replacement %s credential %s written during revocation\n"
                  (Llm_provider.id provider) (stored_name_string name));
            print_env_still_active env_still_active;
            Success)

let row_env_string row =
  match Provider.auth row.provider |> Provider.Auth.env with
  | [] -> "-"
  | env -> env |> List.map Provider.Auth.Env.name |> String.concat ","

let row_source_string row =
  match Spice_account.source (row_account row) with
  | None -> "-"
  | Some source -> (
      let prefix =
        match Spice_account.Credential.Source.tag source with
        | `Process -> "process"
        | `Env -> "env"
        | `Store -> "store"
      in
      match Spice_account.Credential.Source.name source with
      | None -> prefix
      | Some name -> prefix ^ ":" ^ name)

let row_key_string row =
  match row_fingerprint row with
  | None -> "-"
  | Some fingerprint -> "\xE2\x80\xA6" ^ fingerprint

let row_checked_string row =
  match Spice_account.checked_at (row_account row) with
  | None -> "-"
  | Some at -> iso8601 at

let row_store_names_string row =
  match row.store_names with
  | [] -> "-"
  | names -> names |> List.map Credential.Name.to_string |> String.concat ","

let print_status rows =
  print_table
    ~header:
      [
        "PROVIDER";
        "ROUTE";
        "SOURCE";
        "KEY";
        "PHASE";
        "CHECKED";
        "ENV";
        "STORE_NAMES";
      ]
    (List.map
       (fun row ->
         let route =
           Spice_account.credential_kind (row_account row)
           |> Option.map kind_route_label
           |> Option.value ~default:"-"
         in
         [
           row_provider_id row;
           route;
           row_source_string row;
           row_key_string row;
           row_phase_string row;
           row_checked_string row;
           row_env_string row;
           row_store_names_string row;
         ])
       rows)

let print_status_hint row =
  match row_repair row with
  | None -> ()
  | Some repair -> stdout_printf "Hint: run `%s`\n" repair

let status_row ~sw ~stdenv host accounts ?name ~refresh provider_decl =
  let provider = Provider.id provider_decl in
  let account =
    if refresh then
      Account.check ~sw ~stdenv ~now:(timestamp_now stdenv) ?name accounts
        provider
    else
      Account.status ?name accounts provider
      |> Result.map_error (Account.Error.to_host host)
  in
  match account with
  | Error error -> Error (host_error_message error)
  | Ok account -> (
      match Account.names accounts provider with
      | Error error -> Error (Account.Error.message error)
      | Ok store_names ->
          Ok
            {
              provider = provider_decl;
              account;
              store_names;
              selected_model =
                selected_model_for
                  ~connected:(Account.connected accounts)
                  host provider;
            })

let status_rows ~sw ~stdenv host accounts ?name ~refresh providers =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | provider :: providers -> (
        match status_row ~sw ~stdenv host accounts ?name ~refresh provider with
        | Error _ as error -> error
        | Ok row -> loop (row :: acc) providers)
  in
  loop [] providers

let summary_json ~connected host rows =
  match Spice_host.Models.choose ~connected host Model_choice.Main with
  | Error _ -> json_null
  | Ok choice ->
      let model = Model_choice.model choice in
      let provider = Provider.Model.provider model in
      let phase =
        rows
        |> List.find_opt (fun row ->
            Llm_provider.equal (Provider.id row.provider) provider)
        |> Option.map row_phase_string
      in
      json_obj
        [
          ( "selected_route",
            json_obj
              [
                ("provider", Jsont.Json.string (Llm_provider.id provider));
                ("model", Jsont.Json.string (Provider.Model.selector model));
                ("phase", json_null_or_string phase);
              ] );
        ]

let warn_store_permissions path =
  match Unix.stat path with
  | exception Unix.Unix_error _ -> ()
  | stat ->
      let mode = stat.Unix.st_perm land 0o777 in
      if mode land 0o077 <> 0 then
        stderr_printf "spice: warning: %s permissions are %04o, expected 0600\n"
          path mode

let status json name refresh provider_filter =
  with_host @@ fun ~stdenv host ->
  Eio.Switch.run @@ fun sw ->
  match Account.load ~stdenv host with
  | Error error -> Runtime_error (Account.Error.message error)
  | Ok accounts -> (
      (* Storage facts ride along with readiness: the store location, backend,
         and a loud permissions warning, so one command answers both "am I
         logged in" and "where do my credentials live". *)
      let auth_store_path =
        Spice_host.Host.config host
        |> Spice_host.Config.auth_store_path |> Spice_path.Abs.to_string
      in
      warn_store_permissions auth_store_path;
      let storage_fields =
        [
          ("storage_backend", Jsont.Json.string "file");
          ("auth_store_path", Jsont.Json.string auth_store_path);
        ]
      in
      let print_storage () =
        stdout_printf "auth_store_path: %s\n" auth_store_path;
        stdout_printf "storage_backend: file\n"
      in
      match selected_provider provider_filter with
      | Error message -> Usage_error message
      | Ok (Some provider) -> (
          match find_provider_decl host provider with
          | Error message -> Usage_error message
          | Ok provider -> (
              match
                status_row ~sw ~stdenv host accounts ?name ~refresh provider
              with
              | Error message -> Runtime_error message
              | Ok row -> (
                  if json then
                    stdout_printf "%s\n"
                      (json_string
                         (json_obj
                            ([
                               ("schema_version", Jsont.Json.int 3);
                               ("type", Jsont.Json.string "auth_status");
                             ]
                            @ storage_fields
                            @ [ ("providers", json_list [ provider_json row ]) ]
                            )))
                  else (
                    print_storage ();
                    print_status [ row ];
                    print_status_hint row);
                  match row_phase row with
                  | `Missing | `Blocked -> Failed
                  | `Unchecked | `Ready | `Degraded -> Success)))
      | Ok None -> (
          match
            status_rows ~sw ~stdenv host accounts ?name ~refresh
              (Spice_host.Host.providers host)
          with
          | Error message -> Runtime_error message
          | Ok rows ->
              if json then
                stdout_printf "%s\n"
                  (json_string
                     (json_obj
                        ([
                           ("schema_version", Jsont.Json.int 3);
                           ("type", Jsont.Json.string "auth_status");
                         ]
                        @ storage_fields
                        @ [
                            ( "providers",
                              rows |> List.map provider_json |> json_list );
                            ( "summary",
                              summary_json
                                ~connected:(Account.connected accounts)
                                host rows );
                          ])))
              else (
                print_storage ();
                print_status rows);
              Success))

let save provider name api_key_stdin =
  with_host @@ fun ~stdenv host ->
  match find_provider_decl host provider with
  | Error message -> Usage_error message
  | Ok provider_decl -> (
      let provider = Provider.id provider_decl in
      let example =
        api_key_pipe_example provider_decl
          ~command:
            (Printf.sprintf "save %s --api-key-stdin" (Llm_provider.id provider))
      in
      match
        read_api_key ~command:"save" ~example ~prompt:(api_key_prompt provider)
          ~api_key_stdin
      with
      | Error message -> Usage_error message
      | Ok secret -> (
          (* Save-only by design: unlike login, [auth save] runs no post-save
             provider check. *)
          match Account.Store.save ~stdenv ~host ~provider ?name secret with
          | Error error -> Runtime_error (Account.Error.message error)
          | Ok () ->
              stdout_printf "Saved %s credential %s\n"
                (Llm_provider.id provider) (stored_name_string name);
              Success))

let remove provider name = logout provider name false

let provider_arg =
  CArg.(
    required & pos 0 (some Cli_arg.provider) None & info [] ~docv:"PROVIDER")

let name_arg doc =
  CArg.(
    value
    & opt (some Cli_arg.credential_name) None
    & info [ "name" ] ~docv:"NAME" ~doc)

let api_key_stdin_arg =
  CArg.(
    value & flag
    & info [ "api-key-stdin" ]
        ~doc:
          "Read an API key from standard input instead of prompting at the \
           terminal.")

let login_command =
  let method_ =
    CArg.(
      value
      & opt (some login_method) None
      & info [ "m"; "method" ] ~docv:"METHOD"
          ~doc:
            "Use provider-declared login method $(i,METHOD), such as \
             $(b,api-key), $(b,browser), or $(b,device-code).")
  in
  CCmd.v
    (CCmd.info "login" ~doc:"Log in to a provider." ~exits)
    (exit_term
       CTerm.(
         const login $ provider_arg
         $ name_arg "Store credential under name $(i,NAME)."
         $ method_ $ api_key_stdin_arg))

let logout_command =
  let revoke =
    CArg.(
      value & flag
      & info [ "revoke" ]
          ~doc:
            "Revoke the stored credential with the provider before removing it \
             locally.")
  in
  CCmd.v
    (CCmd.info "logout" ~doc:"Log out from a provider." ~exits)
    (exit_term
       CTerm.(
         const logout $ provider_arg
         $ name_arg "Remove stored credential name $(i,NAME)."
         $ revoke))

let status_command =
  let json = Cli_arg.json_flag () in
  let refresh =
    CArg.(
      value & flag
      & info [ "refresh" ]
          ~doc:
            "Validate credentials with the provider and update checked \
             readiness.")
  in
  let positional_provider =
    CArg.(value & pos 0 (some Cli_arg.provider) None & info [] ~docv:"PROVIDER")
  in
  let provider =
    CArg.(
      value
      & opt (some Cli_arg.provider) None
      & info [ "provider" ] ~docv:"PROVIDER"
          ~doc:"Only show one provider. This is equivalent to PROVIDER.")
  in
  CCmd.v
    (CCmd.info "status" ~doc:"Show provider auth readiness." ~exits)
    (exit_term
       CTerm.(
         const status $ json
         $ name_arg "Use stored credential name $(i,NAME)."
         $ refresh
         $ (const provider_filter $ positional_provider $ provider)))

let save_command =
  CCmd.v
    (CCmd.info "save" ~doc:"Store a provider API key." ~exits)
    (exit_term
       CTerm.(
         const save $ provider_arg
         $ name_arg "Store credential under name $(i,NAME)."
         $ api_key_stdin_arg))

let remove_command =
  CCmd.v
    (CCmd.info "remove" ~doc:"Remove stored provider credentials." ~exits)
    (exit_term
       CTerm.(
         const remove $ provider_arg
         $ name_arg "Remove stored credential name $(i,NAME)."))

let group =
  CCmd.group
    (CCmd.info "auth" ~doc:"Manage local provider credentials."
       ~docs:s_config_commands
       ~man:
         [
           `S CManpage.s_description;
           `P
             "Credentials live in a local file store; environment variables \
              take precedence when set. $(b,status) reports per-provider \
              readiness, the storage location, and stored credential names \
              without contacting a provider unless $(b,--refresh) is given.";
           `P
             "On a terminal, API-key $(b,login) and $(b,save) prompt for the \
              key with echo disabled; $(b,--api-key-stdin) reads it from \
              standard input for scripts.";
           `S CManpage.s_examples;
           `Pre "  spice auth login anthropic";
           `Pre
             "  printenv OPENAI_API_KEY | spice auth save openai \
              --api-key-stdin";
           `Pre "  spice auth status openai --refresh";
         ]
       ~envs:
         [
           CCmd.Env.info "SPICE_OPENAI_BASE_URL"
             ~doc:"OpenAI-compatible API base URL override.";
           CCmd.Env.info "SPICE_ANTHROPIC_BASE_URL"
             ~doc:"Anthropic API base URL override.";
         ]
       ~exits)
    [
      status_command;
      login_command;
      logout_command;
      save_command;
      remove_command;
    ]
