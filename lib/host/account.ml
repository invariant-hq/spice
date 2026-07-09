(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

let log_src =
  Logs.Src.create "spice.host.account" ~doc:"Credential store access"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Error = struct
  type t =
    | Unknown_provider of Spice_llm.Provider.t
    | Env of {
        provider : Spice_llm.Provider.t;
        name : string;
        message : string;
      }
    | Store of string

  let message = function
    | Unknown_provider provider ->
        "unknown provider: " ^ Spice_llm.Provider.id provider
    | Env { provider; name; message } ->
        Printf.sprintf "invalid %s credential for provider %s: %s" name
          (Spice_llm.Provider.id provider)
          message
    | Store message -> message

  let to_host host = function
    | Unknown_provider provider ->
        Host.Error.Unknown_provider
          { provider; field = None; known = Host.provider_ids host }
    | Env { provider; name; message } ->
        Host.Error.Credentials
          { provider = Some provider; message = name ^ ": " ^ message }
    | Store message -> Host.Error.Credentials { provider = None; message }

  let pp ppf t = Format.pp_print_string ppf (message t)
end

let provider host id =
  match Host.provider host id with
  | None -> Error (Error.Unknown_provider id)
  | Some provider -> Ok provider

let provider_id host id =
  let* provider = provider host id in
  Ok (Spice_provider.id provider)

let store_error message = Error (Error.Store message)
let fs_path stdenv path = Eio.Path.( / ) (Eio.Stdenv.fs stdenv) path
let file_exists stdenv path = Eio.Path.is_file (fs_path stdenv path)

let mkdir_p stdenv dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path stdenv dir) with
    | () -> Ok ()
    | exception exn -> store_error (Printexc.to_string exn)

let tmp_counter = ref 0

let tmp_path stdenv path =
  incr tmp_counter;
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock stdenv)
    |> Int64.bits_of_float |> Int64.to_string
  in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int !tmp_counter

let with_lock path f =
  let rec lockf fd command =
    match Unix.lockf fd command 0 with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> lockf fd command
  in
  let lock_path = path ^ ".lock" in
  let fd =
    Unix.openfile lock_path [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      (* F_LOCK blocks while another process holds the lock; take it in a
         systhread so the Eio domain keeps running. *)
      Eio_unix.run_in_systhread ~label:"spice-file-lock" (fun () ->
          lockf fd Unix.F_LOCK);
      Fun.protect ~finally:(fun () -> lockf fd Unix.F_ULOCK) f)

let with_store_lock ~stdenv config f =
  let path = Config.auth_store_path config |> Spice_path.Abs.to_string in
  let* () = mkdir_p stdenv (Filename.dirname path) in
  match with_lock path f with
  | result -> result
  | exception exn -> store_error (path ^ ".lock: " ^ Printexc.to_string exn)

module Store_file = struct
  let load ~stdenv config =
    let path = Config.auth_store_path config |> Spice_path.Abs.to_string in
    if not (file_exists stdenv path) then Ok Spice_account.Store.empty
    else
      match Eio.Path.load (fs_path stdenv path) with
      | exception exn -> store_error (path ^ ": " ^ Printexc.to_string exn)
      | text -> (
          match Jsont_bytesrw.decode_string Spice_account.Store.jsont text with
          | Ok store -> Ok store
          | Error message -> store_error (path ^ ": " ^ message))

  let save ~stdenv config store =
    let path = Config.auth_store_path config |> Spice_path.Abs.to_string in
    let* () = mkdir_p stdenv (Filename.dirname path) in
    match Jsont_bytesrw.encode_string Spice_account.Store.jsont store with
    | Error message -> store_error message
    | Ok text -> (
        let tmp = tmp_path stdenv path in
        match
          Eio.Path.save ~create:(`Exclusive 0o600) (fs_path stdenv tmp)
            (text ^ "\n")
        with
        | exception exn -> store_error (path ^ ": " ^ Printexc.to_string exn)
        | () -> (
            match
              Eio.Path.rename (fs_path stdenv tmp) (fs_path stdenv path)
            with
            | () ->
                Log.debug (fun m -> m "auth store written");
                Ok ()
            | exception exn ->
                let () =
                  try Eio.Path.unlink (fs_path stdenv tmp)
                  with cleanup ->
                    Log.debug (fun m ->
                        m "auth store temp cleanup failed: %s"
                          (Printexc.to_string cleanup))
                in
                store_error (path ^ ": " ^ Printexc.to_string exn)))
end

module Store = struct
  let edit ~stdenv config ~f =
    with_store_lock ~stdenv config (fun () ->
        let* store = Store_file.load ~stdenv config in
        Store_file.save ~stdenv config (f store))

  let save ~stdenv ~host ~provider ?name secret =
    let* provider = provider_id host provider in
    let config = Host.config host in
    edit ~stdenv config ~f:(fun store ->
        Spice_account.Store.set ~provider ?name secret store)

  let remove ~stdenv ~host ~provider ?name () =
    let* provider = provider_id host provider in
    let config = Host.config host in
    edit ~stdenv config ~f:(fun store ->
        Spice_account.Store.remove store ~provider ?name ())
end

module Sources = struct
  type t = {
    process : Spice_account.Credential.t list;
    env : Env.t;
    store : Spice_account.Store.t;
  }

  let make ?(process = []) ~env ~store () = { process; env; store }

  let load ~stdenv ?process host =
    let config = Host.config host in
    let* store = Store_file.load ~stdenv config in
    Ok (make ?process ~env:(Config.process_env config) ~store ())
end

type t = { host : Host.t; sources : Sources.t }

let make host sources = { host; sources }

let load ~stdenv ?process host =
  let* sources = Sources.load ~stdenv ?process host in
  Ok (make host sources)

let env_credential sources provider_decl env =
  let provider = Spice_provider.id provider_decl in
  let name = Spice_provider.Auth.Env.name env in
  match Env.get sources.Sources.env name with
  | None | Some "" -> Ok None
  | Some value -> (
      match Spice_provider.Auth.Env.secret env value with
      | Error error ->
          Error
            (Error.Env
               {
                 provider;
                 name;
                 message = Spice_provider.Auth.Env.Error.message error;
               })
      | Ok secret ->
          let source = Spice_account.Credential.Source.env name in
          Ok (Some (Spice_account.Credential.make ~provider ~source secret)))

let env_credentials sources provider_decl =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | env :: envs -> (
        match env_credential sources provider_decl env with
        | Error _ as error -> error
        | Ok None -> loop acc envs
        | Ok (Some credential) -> loop (credential :: acc) envs)
  in
  loop [] (Spice_provider.auth provider_decl |> Spice_provider.Auth.env)

let stored_credential sources ~provider ?name () =
  Spice_account.Store.credential sources.Sources.store ~provider ?name ()

let credential t ?name provider_id =
  let* provider_decl = provider t.host provider_id in
  let sources = t.sources in
  let* env = env_credentials sources provider_decl in
  let store =
    match stored_credential sources ~provider:provider_id ?name () with
    | None -> []
    | Some credential -> [ credential ]
  in
  Ok (Spice_account.resolve (sources.Sources.process @ env @ store) provider_id)

let status t ?name provider =
  match credential t ?name provider with
  | Error _ as error -> error
  | Ok None -> Ok (Spice_account.missing ~provider)
  | Ok (Some credential) -> Ok (Spice_account.present credential)

(* Resolution failures read as not connected: connectivity feeds preferences
   (default-model choice, login nudges, panel locks), never gates a build, so
   a broken source degrades those to their no-account shape rather than
   erroring paths that would otherwise work. *)
let connected t provider =
  match status t provider with
  | Error _ -> false
  | Ok account -> (
      match Spice_account.phase account with
      | `Ready | `Degraded | `Unchecked -> true
      | `Missing | `Blocked -> false)

let connectivity ~stdenv ?process host =
  match load ~stdenv ?process host with
  | Error _ -> fun (_ : Spice_llm.Provider.t) -> false
  | Ok accounts -> connected accounts

let names t provider_id =
  let* _decl = provider t.host provider_id in
  Ok (Spice_account.Store.names t.sources.Sources.store ~provider:provider_id)

let check ~sw ~stdenv ~now ?name t provider =
  let host_error result = Result.map_error (Error.to_host t.host) result in
  let* resolved = host_error (credential t ?name provider) in
  match resolved with
  | None -> Ok (Spice_account.missing ~provider)
  | Some resolved -> (
      match Option.bind (Host.adapter t.host provider) Host.Adapter.check with
      | None -> Ok (Spice_account.present resolved)
      | Some check_route ->
          let config = Host.config t.host in
          let base_url =
            Config.Models.provider_base_url (Config.models config) ~provider
          in
          let* observation = check_route ~sw ~stdenv ?base_url resolved in
          let { Host.Adapter.problems; profile; org; models } = observation in
          Ok
            (Spice_account.checked resolved ~at:now ?profile ?org ~problems
               ?models ()))

let refresh_window_s = 300L

let near_expiry ~now secret =
  match Spice_account.Secret.expires_at secret with
  | None -> false
  | Some at -> Int64.compare at (Int64.add now refresh_window_s) <= 0

let provider_auth_base_url host ~provider =
  let name =
    "SPICE_"
    ^ (Spice_llm.Provider.id provider
      |> String.uppercase_ascii
      |> String.map (fun c ->
          match c with 'A' .. 'Z' | '0' .. '9' -> c | _ -> '_'))
    ^ "_AUTH_BASE_URL"
  in
  match Env.get (Config.process_env (Host.config host)) name with
  | None | Some "" -> None
  | Some value -> Some value

(* The refresh transaction reloads the stored credential under the store lock
   before deciding to refresh, so two processes that race on an expiring token
   cannot both spend the same rotated refresh token: the second sees the first's
   rotation and skips the provider request. Nothing is cached; a permanent
   rejection fails the run loudly with repair guidance. *)
let refresh ~sw ~stdenv ~now ?(force = false) ?name t provider_id =
  match Option.bind (Host.adapter t.host provider_id) Host.Adapter.refresh with
  | None -> Ok None
  | Some refresh_route -> (
      let config = Host.config t.host in
      let auth_base_url = provider_auth_base_url t.host ~provider:provider_id in
      let outcome =
        Result.map_error (Error.to_host t.host)
          (with_store_lock ~stdenv config (fun () ->
               let* store = Store_file.load ~stdenv config in
               match
                 Spice_account.Store.credential store ~provider:provider_id
                   ?name ()
               with
               | None -> Ok `Nothing
               | Some stored -> (
                   let secret = Spice_account.Credential.secret stored in
                   if
                     (not (Spice_account.Secret.has_refresh_token secret))
                     || not (force || near_expiry ~now secret)
                   then Ok (`Refreshed (Some stored))
                   else
                     match
                       refresh_route ~sw ~stdenv ~now ?auth_base_url secret
                     with
                     | Ok refreshed ->
                         let store =
                           Spice_account.Store.set ~provider:provider_id ?name
                             refreshed store
                         in
                         let* () = Store_file.save ~stdenv config store in
                         Ok
                           (`Refreshed
                              (Spice_account.Store.credential store
                                 ~provider:provider_id ?name ()))
                     | Error problem
                       when Spice_account.Problem.transient problem ->
                         Ok `Nothing
                     | Error problem -> Ok (`Fatal problem))))
      in
      match outcome with
      | Error _ as error -> error
      | Ok `Nothing -> Ok None
      | Ok (`Refreshed credential) ->
          Log.debug (fun m ->
              m "credential refreshed provider=%s"
                (Spice_llm.Provider.id provider_id));
          Ok credential
      | Ok (`Fatal problem) ->
          Error
            (Host.Error.Blocked_credential
               { provider = provider_id; problems = [ problem ] }))
