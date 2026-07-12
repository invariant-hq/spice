(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Mode = struct
  type t = Read_only | Workspace_write | Danger_full_access | External_sandbox

  let all = [ Read_only; Workspace_write; Danger_full_access; External_sandbox ]

  let to_string = function
    | Read_only -> "read-only"
    | Workspace_write -> "workspace-write"
    | Danger_full_access -> "danger-full-access"
    | External_sandbox -> "external-sandbox"

  let of_string = function
    | "read-only" -> Some Read_only
    | "workspace-write" -> Some Workspace_write
    | "danger-full-access" -> Some Danger_full_access
    | "external-sandbox" -> Some External_sandbox
    | _ -> None

  let equal a b =
    match (a, b) with
    | Read_only, Read_only
    | Workspace_write, Workspace_write
    | Danger_full_access, Danger_full_access
    | External_sandbox, External_sandbox ->
        true
    | (Read_only | Workspace_write | Danger_full_access | External_sandbox), _
      ->
        false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Require = struct
  type t = Off | Enforced_or_external | Enforced

  let all = [ Off; Enforced_or_external; Enforced ]

  let to_string = function
    | Off -> "off"
    | Enforced_or_external -> "enforced-or-external"
    | Enforced -> "enforced"

  let of_string = function
    | "off" -> Some Off
    | "enforced-or-external" -> Some Enforced_or_external
    | "enforced" -> Some Enforced
    | _ -> None

  let equal a b =
    match (a, b) with
    | Off, Off | Enforced_or_external, Enforced_or_external | Enforced, Enforced
      ->
        true
    | (Off | Enforced_or_external | Enforced), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Network = Spice_sandbox.Policy.Network

module Gate_error = struct
  type t =
    | Backend_unavailable of { mode : Mode.t; reason : Spice_sandbox.Error.t }
    | External_not_enforced

  let message = function
    | Backend_unavailable { mode; reason } ->
        Printf.sprintf
          "sandbox unavailable: %s requested, %s\n\
           next: run `spice sandbox status`, choose `--sandbox \
           danger-full-access`, or declare `external-sandbox`"
          (Mode.to_string mode)
          (Spice_sandbox.Error.message reason)
    | External_not_enforced ->
        "sandbox unavailable: a declared external sandbox does not satisfy \
         sandbox.require=enforced\n\
         next: set sandbox.require=enforced-or-external to accept the declared \
         boundary, or choose an enforceable mode"

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Resolve_error = struct
  type t =
    | Invalid_scratch_base of Spice_path.Error.t
    | Scratch_creation_failed of string
    | Invalid_environment of Spice_sandbox.Environment.Error.t

  let message = function
    | Invalid_scratch_base error ->
        "invalid TMPDIR for sandbox scratch: " ^ Spice_path.Error.message error
    | Scratch_creation_failed message ->
        "could not create sandbox scratch directory: " ^ message
    | Invalid_environment error ->
        Spice_sandbox.Environment.Error.message error

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Status = struct
  type origin = Flag | Config | Default
  type network = Restricted | Enabled | External

  type t = {
    mode : Mode.t;
    origin : origin;
    require : Require.t;
    enforcement : Spice_sandbox.Evidence.t;
    network : network;
    backend : string;
  }

  let available t =
    match t.enforcement with
    | Spice_sandbox.Evidence.Refused _ -> false
    | Spice_sandbox.Evidence.Enforced _ | Spice_sandbox.Evidence.Not_requested
    | Spice_sandbox.Evidence.Declared_external ->
        true

  let origin_string = function
    | Flag -> "flag"
    | Config -> "config"
    | Default -> "default"

  let enforcement_string = function
    | Spice_sandbox.Evidence.Enforced _ -> "enforceable"
    | Spice_sandbox.Evidence.Refused _ -> "refused"
    | Spice_sandbox.Evidence.Not_requested -> "not_requested"
    | Spice_sandbox.Evidence.Declared_external -> "declared"

  let network_string = function
    | Restricted -> "restricted"
    | Enabled -> "enabled"
    | External -> "external"
end

(* Workspace-write protects the version-control and Spice metadata dirs even
   inside otherwise writable roots, so a run cannot rewrite its own history or
   authority state. The names are shared with the edit-tool write guard
   ([Spice_workspace_fs.protected_meta_component]) so the confined shell and the
   native edit tools protect exactly the same metadata. *)
let protected_meta_names = Spice_workspace_fs.protected_meta_names

(* Network applies to both confined modes: read-only and workspace-write can
   each opt into outbound access without becoming unconfined. Unconfined and
   declared-external already own network by construction. *)
let sandbox_of_mode ~environment ~writable ~protect ~network = function
  | Mode.Read_only ->
      Spice_sandbox.Policy.confined ~reads:Spice_sandbox.Policy.All
        ~writable_roots:[] ~protected_meta:[] ~protected_paths:[] ~network
        ~environment
  | Mode.Workspace_write ->
      Spice_sandbox.Policy.confined ~reads:Spice_sandbox.Policy.All
        ~writable_roots:writable ~protected_meta:protected_meta_names
        ~protected_paths:protect ~network ~environment
  | Mode.Danger_full_access -> Spice_sandbox.Policy.direct ~environment
  | Mode.External_sandbox -> Spice_sandbox.Policy.external_ ~environment

module Effective = struct
  type t = {
    mode : Mode.t;
    origin : Status.origin;
    require : Require.t;
    policy : Spice_sandbox.Policy.t;
    backend : Spice_sandbox.Backend.t;
    sandbox : Spice_sandbox.t;
  }

  let policy t = t.policy
  let backend t = t.backend
  let sandbox t = t.sandbox

  (* The gate needs the refusal reason; Status.available only needs the bool.
     Both derive from the sealed evidence, so they cannot disagree. *)
  let backend_available t =
    match Spice_sandbox.evidence t.sandbox with
    | Spice_sandbox.Evidence.Refused reason -> Error reason
    | Spice_sandbox.Evidence.Enforced _ | Spice_sandbox.Evidence.Not_requested
    | Spice_sandbox.Evidence.Declared_external ->
        Ok ()

  let network t =
    match t.policy with
    | Spice_sandbox.Policy.Direct _ -> Status.Enabled
    | Spice_sandbox.Policy.External _ -> Status.External
    | Spice_sandbox.Policy.Confined policy -> (
        match policy.network with
        | Spice_sandbox.Policy.Network.Restricted -> Status.Restricted
        | Spice_sandbox.Policy.Network.Enabled -> Status.Enabled)

  (* Unconfined and declared-external runs have no enforcing backend; naming
     the platform's candidate would be misleading and platform-dependent. *)
  let backend_display t =
    match t.policy with
    | Spice_sandbox.Policy.Direct _ -> "none"
    | Spice_sandbox.Policy.External _ -> "external"
    | Spice_sandbox.Policy.Confined _ -> Spice_sandbox.Backend.id t.backend

  let status t =
    {
      Status.mode = t.mode;
      origin = t.origin;
      require = t.require;
      enforcement = Spice_sandbox.evidence t.sandbox;
      network = network t;
      backend = backend_display t;
    }
end

(* Canonicalize where the path exists so the policy describes what the
   backend enforces (macOS /tmp is a symlink to /private/tmp). A path that
   cannot be resolved keeps its lexical spelling. *)
let canonical path =
  match Unix.realpath (Spice_path.Abs.to_string path) with
  | real -> (
      match Spice_path.Abs.of_string real with
      | Ok real -> real
      | Error _ -> path)
  | exception Unix.Unix_error _ -> path

(* Expand a leading [~] against [$HOME] and parse to an absolute path. A bare
   relative spelling has no unambiguous meaning for a writable root, so only
   [~]-prefixed and already-absolute spellings resolve; anything else is
   dropped by the [Abs.of_string] parse. *)
let abs_of_config_path ~env spelling =
  let expanded =
    if String.equal spelling "~" then env "HOME"
    else if String.length spelling >= 2 && String.sub spelling 0 2 = "~/" then
      match env "HOME" with
      | Some home ->
          Some (home ^ String.sub spelling 1 (String.length spelling - 1))
      | None -> None
    else Some spelling
  in
  match expanded with
  | None -> None
  | Some path -> Result.to_option (Spice_path.Abs.of_string path)

let config_writable_roots ~env spellings =
  List.filter_map (abs_of_config_path ~env) spellings

(* The dune cache root, in dune's own precedence: an explicit [$DUNE_CACHE_ROOT],
   else [$XDG_CACHE_HOME/dune], else [~/.cache/dune] (XDG on macOS too — dune
   does not use [~/Library/Caches]). Directory existence is not required here;
   the seal step and backends tolerate an absent root. *)
let dune_cache_root ~env =
  let of_string s = Result.to_option (Spice_path.Abs.of_string s) in
  match env "DUNE_CACHE_ROOT" with
  | Some value when value <> "" -> of_string value
  | _ -> (
      match env "XDG_CACHE_HOME" with
      | Some value when value <> "" -> of_string (value ^ "/dune")
      | _ -> (
          match env "HOME" with
          | Some home when home <> "" -> of_string (home ^ "/.cache/dune")
          | _ -> None))

let is_dune_project workspace =
  List.exists
    (fun root ->
      let dir = Spice_path.Abs.to_string (Spice_workspace.Root.dir root) in
      Sys.file_exists (Filename.concat dir "dune-project"))
    (Spice_workspace.roots workspace)

(* Curated per-toolchain cache roots: today just dune's, when the workspace is a
   dune project. Kept small and explicit; new ecosystems are added by decision,
   not by pattern. *)
let toolchain_cache_roots ~env ~workspace =
  if is_dune_project workspace then Option.to_list (dune_cache_root ~env)
  else []

let is_linux () =
  String.equal Sys.os_type "Unix" && Sys.file_exists "/proc/sys/kernel/ostype"

let forced_unavailable ~env =
  match env "_SPICE_TEST_SANDBOX_UNAVAILABLE" with
  | None -> None
  | Some "1" ->
      Some
        (Spice_sandbox.Backend.none
           ~reason:
             "sandbox backend forced unavailable \
              (_SPICE_TEST_SANDBOX_UNAVAILABLE=1)")
  | Some other ->
      Some
        (Spice_sandbox.Backend.none
           ~reason:
             (Printf.sprintf "unknown _SPICE_TEST_SANDBOX_UNAVAILABLE value %S"
                other))

let bubblewrap_probe_timeout = 1.0
let bubblewrap_probe_cache = Atomic.make None

let process_status_text = function
  | `Exited code -> Printf.sprintf "exited %d" code
  | `Signaled signal -> Printf.sprintf "signaled %d" signal

let run_bubblewrap_probe ~stdenv ~executable ~argv =
  let clock = Eio.Stdenv.clock stdenv in
  let process_mgr = Eio.Stdenv.process_mgr stdenv in
  let ( / ) = Eio.Path.( / ) in
  let null_path = Eio.Stdenv.fs stdenv / "/dev/null" in
  try
    match
      Eio.Time.with_timeout clock bubblewrap_probe_timeout (fun () ->
          Ok
            (Eio.Path.with_open_out ~create:`Never null_path (fun null ->
                 (* The child belongs to this inner switch. Timeout or caller
                    cancellation releases it, which kills and reaps the child
                    before the exception can leave [Switch.run]. *)
                 Eio.Switch.run (fun sw ->
                     let process =
                       Eio.Process.spawn ~sw process_mgr ~stdin:null
                         ~stdout:null ~stderr:null ~executable
                         (Array.to_list argv)
                     in
                     Eio.Process.await process))))
    with
    | Ok (`Exited 0) -> Ok ()
    | Ok status -> Error (process_status_text status)
    | Error `Timeout ->
        Error (Printf.sprintf "timed out after %gs" bubblewrap_probe_timeout)
  with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | ex -> Error (Printexc.to_string ex)

let cached_bubblewrap_probe ~stdenv ~executable ~argv =
  match Atomic.get bubblewrap_probe_cache with
  | Some result -> result
  | None ->
      let result = run_bubblewrap_probe ~stdenv ~executable ~argv in
      ignore (Atomic.compare_and_set bubblewrap_probe_cache None (Some result));
      result

let bubblewrap_backend ~stdenv ~cached probe_executable =
  let probe =
    if cached then cached_bubblewrap_probe ~stdenv
    else run_bubblewrap_probe ~stdenv
  in
  Spice_sandbox.Bubblewrap.make ~probe_executable ~probe ()

(* Backend selection is platform-owned. The environment seams force only
   deterministic availability behavior for blackbox tests; production backend
   selection and enforcement prefixes remain fixed. *)
let host_backend ~stdenv ~env =
  match forced_unavailable ~env with
  | Some backend -> backend
  | None -> (
      match env "_SPICE_TEST_BUBBLEWRAP_PROBE" with
      | Some executable -> bubblewrap_backend ~stdenv ~cached:false executable
      | None when is_linux () ->
          bubblewrap_backend ~stdenv ~cached:true
            Spice_sandbox.Bubblewrap.executable
      | None when Sys.file_exists Spice_sandbox.Seatbelt.executable ->
          Spice_sandbox.Seatbelt.backend
      | None ->
          Spice_sandbox.Backend.none
            ~reason:"no supported sandbox backend on this platform")

let ( let* ) = Result.bind

let scratch_base ~env =
  match env "TMPDIR" with
  | None -> Ok (Spice_path.Abs.of_string_exn "/tmp")
  | Some path ->
      Spice_path.Abs.of_string path
      |> Result.map_error (fun error -> Resolve_error.Invalid_scratch_base error)

let create_scratch ~sw ~stdenv ~env =
  let* base = scratch_base ~env in
  let base = Spice_path.Abs.to_string base in
  match Filename.temp_dir ~temp_dir:base "spice-sandbox-" "" with
  | path -> (
      match Unix.chmod path 0o700 with
      | () -> (
          match Spice_path.Abs.of_string path with
          | Error error ->
              Error
                (Resolve_error.Scratch_creation_failed
                   (Spice_path.Error.message error))
          | Ok scratch ->
              let scratch = canonical scratch in
              let fs = Eio.Stdenv.fs stdenv in
              Eio.Switch.on_release sw (fun () ->
                  let ( / ) = Eio.Path.( / ) in
                  Eio.Path.rmtree ~missing_ok:true
                    (fs / Spice_path.Abs.to_string scratch));
              Ok scratch)
      | exception Unix.Unix_error (error, fn, arg) ->
          Error
            (Resolve_error.Scratch_creation_failed
               (Printf.sprintf "%s in %s(%s)" (Unix.error_message error) fn arg)))
  | exception exn ->
      Error (Resolve_error.Scratch_creation_failed (Printexc.to_string exn))

let resolve ~sw ?flag ?config_mode ?(require = Require.Enforced) ?(protect = [])
    ?(writable_roots = []) ?(network = Network.Restricted)
    ?(toolchain_caches = true) ~stdenv ~env ~workspace () =
  let* scratch = create_scratch ~sw ~stdenv ~env in
  let* environment =
    Spice_sandbox.Environment.make
      ~path:(Option.value (env "PATH") ~default:"")
      ~scratch ~user_names:[] ~launch:env
    |> Result.map_error (fun error -> Resolve_error.Invalid_environment error)
  in
  let mode, origin =
    match (flag, config_mode) with
    | Some mode, _ -> (mode, Status.Flag)
    | None, Some mode -> (mode, Status.Config)
    | None, None -> (Mode.Workspace_write, Status.Default)
  in
  let preset_roots =
    if toolchain_caches then toolchain_cache_roots ~env ~workspace else []
  in
  let writable =
    List.map
      (fun root -> canonical (Spice_workspace.Root.dir root))
      (Spice_workspace.roots workspace)
    @ List.map canonical (config_writable_roots ~env writable_roots)
    @ List.map canonical preset_roots
  in
  let protect = List.map canonical protect in
  let policy = sandbox_of_mode ~environment ~writable ~protect ~network mode in
  let backend = host_backend ~stdenv ~env in
  let sandbox = Spice_sandbox.seal ~backend policy in
  Ok { Effective.mode; origin; require; policy; backend; sandbox }

let gate effective =
  match
    (Effective.policy effective, (effective.Effective.require : Require.t))
  with
  | _, Require.Off -> Ok ()
  | Spice_sandbox.Policy.Direct _, _ -> Ok ()
  | Spice_sandbox.Policy.External _, Require.Enforced_or_external -> Ok ()
  | Spice_sandbox.Policy.External _, Require.Enforced ->
      Error Gate_error.External_not_enforced
  | Spice_sandbox.Policy.Confined _, _ -> (
      match Effective.backend_available effective with
      | Ok () -> Ok ()
      | Error reason ->
          Error
            (Gate_error.Backend_unavailable
               { mode = effective.Effective.mode; reason }))

let mutating_tools effective =
  match effective.Effective.mode with
  | Mode.Read_only -> false
  | Mode.Workspace_write | Mode.Danger_full_access | Mode.External_sandbox ->
      true

let enforces_workspace_write effective =
  match effective.Effective.mode with
  | Mode.Workspace_write ->
      Result.is_ok (Effective.backend_available effective)
  | Mode.Read_only | Mode.Danger_full_access | Mode.External_sandbox -> false
