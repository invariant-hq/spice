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

module Network = struct
  type t = Restricted | Enabled

  let all = [ Restricted; Enabled ]

  let to_string = function Restricted -> "restricted" | Enabled -> "enabled"

  let of_string = function
    | "restricted" -> Some Restricted
    | "enabled" -> Some Enabled
    | _ -> None

  let equal a b =
    match (a, b) with
    | Restricted, Restricted | Enabled, Enabled -> true
    | (Restricted | Enabled), _ -> false

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

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

let confinement_network = function
  | Network.Restricted -> Spice_sandbox.Confinement.Restricted
  | Network.Enabled -> Spice_sandbox.Confinement.Enabled

(* Network applies to both confined modes: read-only and workspace-write can
   each opt into outbound access without becoming unconfined. Unconfined and
   declared-external already own network by construction. *)
let sandbox_of_mode ~writable ~protect ~network = function
  | Mode.Read_only ->
      Spice_sandbox.Spec.Confined
        (Spice_sandbox.Confinement.read_only
        |> Spice_sandbox.Confinement.network (confinement_network network))
  | Mode.Workspace_write ->
      Spice_sandbox.Spec.Confined
        (Spice_sandbox.Confinement.read_only
        |> Spice_sandbox.Confinement.writable writable
        |> Spice_sandbox.Confinement.protect_meta protected_meta_names
        |> Spice_sandbox.Confinement.protect protect
        |> Spice_sandbox.Confinement.network (confinement_network network))
  | Mode.Danger_full_access -> Spice_sandbox.Spec.Unconfined
  | Mode.External_sandbox -> Spice_sandbox.Spec.Declared_external

module Effective = struct
  type t = {
    mode : Mode.t;
    origin : Status.origin;
    require : Require.t;
    spec : Spice_sandbox.Spec.t;
    backend : Spice_sandbox.Backend.t;
    sandbox : Spice_sandbox.t;
  }

  let spec t = t.spec
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
    match t.spec with
    | Spice_sandbox.Spec.Unconfined -> Status.Enabled
    | Spice_sandbox.Spec.Declared_external -> Status.External
    | Spice_sandbox.Spec.Confined policy -> (
        match Spice_sandbox.Confinement.network_state policy with
        | Spice_sandbox.Confinement.Restricted -> Status.Restricted
        | Spice_sandbox.Confinement.Enabled -> Status.Enabled)

  (* Unconfined and declared-external runs have no enforcing backend; naming
     the platform's candidate would be misleading and platform-dependent. *)
  let backend_display t =
    match t.spec with
    | Spice_sandbox.Spec.Unconfined -> "none"
    | Spice_sandbox.Spec.Declared_external -> "external"
    | Spice_sandbox.Spec.Confined _ -> Spice_sandbox.Backend.id t.backend

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

let temp_dirs ~env =
  let tmpdir =
    match env "TMPDIR" with
    | None -> []
    | Some value -> (
        match Spice_path.Abs.of_string value with
        | Ok path -> [ path ]
        | Error _ -> [])
  in
  (match Spice_path.Abs.of_string "/tmp" with
    | Ok tmp when Sys.file_exists "/tmp" -> [ tmp ]
    | Ok _ | Error _ -> [])
  @ tmpdir

(* Expand a leading [~] against [$HOME] and parse to an absolute path. A bare
   relative spelling has no unambiguous meaning for a writable root, so only
   [~]-prefixed and already-absolute spellings resolve; anything else is
   dropped by the [Abs.of_string] parse. *)
let abs_of_config_path ~env spelling =
  let expanded =
    if String.equal spelling "~" then env "HOME"
    else if String.length spelling >= 2 && String.sub spelling 0 2 = "~/" then
      match env "HOME" with
      | Some home -> Some (home ^ String.sub spelling 1 (String.length spelling - 1))
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
   the seal step and backend tolerate an absent root, and the run creates it. *)
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
  if is_dune_project workspace then Option.to_list (dune_cache_root ~env) else []

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

(* Backend selection is platform-owned. The environment seam only forces an
   unavailable backend for blackbox tests; it does not select an implementation.
*)
let host_backend ~env =
  match forced_unavailable ~env with
  | Some backend -> backend
  | None when is_linux () -> Spice_sandbox.Bubblewrap.backend
  | None when Sys.file_exists Spice_sandbox.Seatbelt.executable ->
      Spice_sandbox.Seatbelt.backend
  | None ->
      Spice_sandbox.Backend.none
        ~reason:"no supported sandbox backend on this platform"

let resolve ?flag ?config_mode ?(require = Require.Enforced) ?(protect = [])
    ?(writable_roots = []) ?(network = Network.Restricted)
    ?(toolchain_caches = true) ~env ~workspace () =
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
    @ List.map canonical (temp_dirs ~env)
    @ List.map canonical (config_writable_roots ~env writable_roots)
    @ List.map canonical preset_roots
  in
  let protect = List.map canonical protect in
  let spec = sandbox_of_mode ~writable ~protect ~network mode in
  let backend = host_backend ~env in
  let sandbox = Spice_sandbox.seal ~backend spec in
  { Effective.mode; origin; require; spec; backend; sandbox }

let gate effective =
  match
    (Effective.spec effective, (effective.Effective.require : Require.t))
  with
  | _, Require.Off -> Ok ()
  | Spice_sandbox.Spec.Unconfined, _ -> Ok ()
  | Spice_sandbox.Spec.Declared_external, Require.Enforced_or_external -> Ok ()
  | Spice_sandbox.Spec.Declared_external, Require.Enforced ->
      Error Gate_error.External_not_enforced
  | Spice_sandbox.Spec.Confined _, _ -> (
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
