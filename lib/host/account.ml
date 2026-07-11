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

module Revoke = struct
  type remote = Revoked | Unsupported | Failed of Spice_account.Problem.t
  type local = Removed | Superseded
  type t = Not_stored | Settled of { remote : remote; local : local }
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
let dir_exists stdenv path = Eio.Path.is_directory (fs_path stdenv path)

let mkdir_p stdenv dir =
  if String.is_empty dir || String.equal dir "." then Ok ()
  else
    match Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path stdenv dir) with
    | () -> Ok ()
    | exception exn -> store_error (Printexc.to_string exn)

let tmp_counter = Atomic.make 0

let tmp_path stdenv path =
  let counter = Atomic.fetch_and_add tmp_counter 1 in
  let stamp =
    Eio.Time.now (Eio.Stdenv.clock stdenv)
    |> Int64.bits_of_float |> Int64.to_string
  in
  path ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ stamp ^ "." ^ string_of_int counter

type lock_mutex = { mutex : Eio.Mutex.t; mutable users : int }

let lock_mutexes : (string, lock_mutex) Hashtbl.t = Hashtbl.create 8
let lock_mutexes_guard = Mutex.create ()

let acquire_lock_mutex key =
  Mutex.protect lock_mutexes_guard (fun () ->
      match Hashtbl.find_opt lock_mutexes key with
      | Some entry ->
          entry.users <- entry.users + 1;
          entry
      | None ->
          let entry = { mutex = Eio.Mutex.create (); users = 1 } in
          Hashtbl.add lock_mutexes key entry;
          entry)

let release_lock_mutex key entry =
  Mutex.protect lock_mutexes_guard (fun () ->
      match Hashtbl.find_opt lock_mutexes key with
      | Some current when current == entry ->
          assert (entry.users > 0);
          entry.users <- entry.users - 1;
          if entry.users = 0 then Hashtbl.remove lock_mutexes key
      | Some _ | None -> assert false)

let canonical_lock_key path =
  try
    let dir =
      Eio_unix.run_in_systhread ~label:"spice-auth-lock-realpath" (fun () ->
          Unix.realpath (Filename.dirname path))
    in
    dir ^ "/" ^ Filename.basename path
  with Unix.Unix_error _ -> path

exception Lock_failure of exn

let lock_operation f =
  match f () with
  | value -> value
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception (Lock_failure _ as exn) -> raise exn
  | exception exn -> raise (Lock_failure exn)

let preserving_cleanup ~path cleanup f =
  match f () with
  | value ->
      cleanup ();
      value
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      (match cleanup () with
      | () -> ()
      | exception Lock_failure cleanup_error ->
          Log.err (fun m ->
              m "account lock cleanup failed path=%s error=%s" path
                (Printexc.to_string cleanup_error)));
      Printexc.raise_with_backtrace exn backtrace

let with_lock ~stdenv path f =
  let rec lockf fd command =
    match Unix.lockf fd command 0 with
    | () -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> lockf fd command
  in
  let lock_path = path ^ ".lock" in
  let key = canonical_lock_key lock_path in
  let entry = acquire_lock_mutex key in
  Fun.protect
    ~finally:(fun () -> release_lock_mutex key entry)
    (fun () ->
      Eio.Mutex.use_ro entry.mutex (fun () ->
          let fd =
            lock_operation (fun () ->
                Unix.openfile lock_path
                  [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
                  0o600)
          in
          preserving_cleanup ~path:lock_path
            (fun () -> lock_operation (fun () -> Unix.close fd))
            (fun () ->
              let rec acquire backoff =
                match Unix.lockf fd Unix.F_TLOCK 0 with
                | () -> ()
                | exception Unix.Unix_error (Unix.EINTR, _, _) ->
                    acquire backoff
                | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _)
                  ->
                    Eio.Time.sleep (Eio.Stdenv.clock stdenv) backoff;
                    acquire (Float.min (backoff *. 2.) 0.1)
                | exception exn -> raise (Lock_failure exn)
              in
              acquire 0.001;
              preserving_cleanup ~path:lock_path
                (fun () -> lock_operation (fun () -> lockf fd Unix.F_ULOCK))
                f)))

let auth_store_path config =
  Config.auth_store_path config |> Spice_path.Abs.to_string

let with_store_lock ~stdenv config f =
  let path = auth_store_path config in
  let* () = mkdir_p stdenv (Filename.dirname path) in
  match with_lock ~stdenv path f with
  | result -> result
  | exception Lock_failure exn ->
      store_error (path ^ ".lock: " ^ Printexc.to_string exn)

let credential_lock_path config provider name =
  let slot =
    Spice_digest.key ~length:64 ~domain:"spice.host.account.credential-lock.v1"
      [
        Spice_llm.Provider.id provider;
        Spice_account.Credential.Name.to_string name;
      ]
  in
  auth_store_path config ^ ".credential-" ^ slot

let with_credential_lock ~stdenv config ~provider ~name f =
  let path = credential_lock_path config provider name in
  let* () = mkdir_p stdenv (Filename.dirname path) in
  match with_lock ~stdenv path f with
  | result -> result
  | exception Lock_failure exn ->
      store_error (path ^ ".lock: " ^ Printexc.to_string exn)

module Store_file = struct
  let load ~stdenv config =
    let path = Config.auth_store_path config |> Spice_path.Abs.to_string in
    if file_exists stdenv path then
      match Eio.Path.load (fs_path stdenv path) with
      | exception exn -> store_error (path ^ ": " ^ Printexc.to_string exn)
      | text -> (
          match Jsont_bytesrw.decode_string Spice_account.Store.jsont text with
          | Ok store -> Ok store
          | Error message -> store_error (path ^ ": " ^ message))
    else if dir_exists stdenv path then store_error (path ^ ": is a directory")
    else Ok Spice_account.Store.empty

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
  match Spice_account.resolve sources.Sources.process provider_id with
  | Some credential -> Ok (Some credential)
  | None -> (
      let* env = env_credentials sources provider_decl in
      match Spice_account.resolve env provider_id with
      | Some credential -> Ok (Some credential)
      | None -> Ok (stored_credential sources ~provider:provider_id ?name ()))

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

let stored_name credential =
  match Spice_account.Credential.source credential with
  | Spice_account.Credential.Source.Store name -> Some name
  | Spice_account.Credential.Source.Process
  | Spice_account.Credential.Source.Env _ ->
      None

let same_secret a b =
  Spice_account.Secret.equal
    (Spice_account.Credential.secret a)
    (Spice_account.Credential.secret b)

let refresh ~sw ~stdenv ~now ?(force = false) t expected =
  let provider = Spice_account.Credential.provider expected in
  let expected_secret = Spice_account.Credential.secret expected in
  match
    ( stored_name expected,
      Option.bind (Host.adapter t.host provider) Host.Adapter.refresh )
  with
  | None, _ | _, None -> Ok (Some expected)
  | Some _, Some _
    when (not force)
         && ((not (Spice_account.Secret.has_refresh_token expected_secret))
            || not (near_expiry ~now expected_secret)) ->
      Ok (Some expected)
  | Some name, Some refresh_route -> (
      let config = Host.config t.host in
      let auth_base_url = provider_auth_base_url t.host ~provider in
      let outcome =
        with_credential_lock ~stdenv config ~provider ~name (fun () ->
            let* snapshot =
              with_store_lock ~stdenv config (fun () ->
                  let* store = Store_file.load ~stdenv config in
                  Ok (Spice_account.Store.credential store ~provider ~name ()))
            in
            match snapshot with
            | None -> Ok (`Current None)
            | Some current when not (same_secret current expected) ->
                Ok (`Current (Some current))
            | Some current -> (
                let secret = Spice_account.Credential.secret current in
                if
                  (not (Spice_account.Secret.has_refresh_token secret))
                  || ((not force) && not (near_expiry ~now secret))
                then Ok (`Current (Some current))
                else
                  let settle decide =
                    with_store_lock ~stdenv config (fun () ->
                        let* store = Store_file.load ~stdenv config in
                        match
                          Spice_account.Store.credential store ~provider ~name
                            ()
                        with
                        | None -> Ok (`Current None)
                        | Some present when not (same_secret present current) ->
                            Ok (`Current (Some present))
                        | Some present -> decide store present)
                  in
                  match
                    refresh_route ~sw ~stdenv ~now ?auth_base_url secret
                  with
                  | Error problem ->
                      settle (fun _store present ->
                          if Spice_account.Problem.transient problem then
                            Ok (`Current (Some present))
                          else Ok (`Fatal problem))
                  | Ok replacement ->
                      Eio.Cancel.protect (fun () ->
                          settle (fun store _present ->
                              let store =
                                Spice_account.Store.set ~provider ~name
                                  replacement store
                              in
                              let* () = Store_file.save ~stdenv config store in
                              Ok
                                (`Committed
                                   (Spice_account.Store.credential store
                                      ~provider ~name ()))))))
      in
      match Result.map_error (Error.to_host t.host) outcome with
      | Error _ as error -> error
      | Ok (`Current credential) -> Ok credential
      | Ok (`Committed credential) ->
          Log.debug (fun m ->
              m "credential refreshed provider=%s"
                (Spice_llm.Provider.id provider));
          Ok credential
      | Ok (`Fatal problem) ->
          Error
            (Host.Error.Blocked_credential { provider; problems = [ problem ] })
      )

let revoke ~sw ~stdenv ~host ~provider
    ?(name = Spice_account.Credential.Name.default) () =
  let* provider = provider_id host provider in
  let config = Host.config host in
  with_credential_lock ~stdenv config ~provider ~name (fun () ->
      let* snapshot =
        with_store_lock ~stdenv config (fun () ->
            let* store = Store_file.load ~stdenv config in
            Ok (Spice_account.Store.credential store ~provider ~name ()))
      in
      match snapshot with
      | None -> Ok Revoke.Not_stored
      | Some snapshot ->
          let secret = Spice_account.Credential.secret snapshot in
          let auth_base_url = provider_auth_base_url host ~provider in
          let remote =
            match
              Option.bind (Host.adapter host provider) Host.Adapter.revoke
            with
            | None -> Revoke.Unsupported
            | Some route -> (
                match route ~sw ~stdenv ?auth_base_url secret with
                | Ok () -> Revoke.Revoked
                | Error Spice_account.Problem.Unsupported -> Revoke.Unsupported
                | Error problem -> Revoke.Failed problem)
          in
          Eio.Cancel.protect (fun () ->
              with_store_lock ~stdenv config (fun () ->
                  let* store = Store_file.load ~stdenv config in
                  match
                    Spice_account.Store.credential store ~provider ~name ()
                  with
                  | Some current when not (same_secret current snapshot) ->
                      Ok (Revoke.Settled { remote; local = Revoke.Superseded })
                  | None ->
                      Ok (Revoke.Settled { remote; local = Revoke.Removed })
                  | Some _ ->
                      let store =
                        Spice_account.Store.remove store ~provider ~name ()
                      in
                      let* () = Store_file.save ~stdenv config store in
                      Ok (Revoke.Settled { remote; local = Revoke.Removed }))))
