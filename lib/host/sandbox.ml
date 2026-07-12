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

module Read = struct
  type t = Project | All

  let all = [ Project; All ]
  let to_string = function Project -> "project" | All -> "all"

  let of_string = function
    | "project" -> Some Project
    | "all" -> Some All
    | _ -> None

  let equal a b =
    match a, b with
    | Project, Project | All, All -> true
    | (Project | All), _ -> false

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

type root_origin =
  | Workspace
  | Platform
  | Toolchain of string
  | Executable of string
  | Git_worktree
  | Scratch
  | User_configured

let root_origin_to_string = function
  | Workspace -> "workspace"
  | Platform -> "platform"
  | Toolchain name -> "toolchain:" ^ name
  | Executable name -> "executable:" ^ name
  | Git_worktree -> "git-worktree"
  | Scratch -> "scratch"
  | User_configured -> "user-configured"

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
    | Invalid_root of {
        field : string;
        index : int option;
        spelling : string;
        reason : string;
      }
    | Broad_root of { field : string; path : Spice_path.Abs.t }
    | Redundant_readable_roots

  let message = function
    | Invalid_scratch_base error ->
        "invalid TMPDIR for sandbox scratch: " ^ Spice_path.Error.message error
    | Scratch_creation_failed message ->
        "could not create sandbox scratch directory: " ^ message
    | Invalid_environment error ->
        Spice_sandbox.Environment.Error.message error
    | Invalid_root { field; index; spelling; reason } ->
        let index =
          match index with
          | None -> ""
          | Some index -> Printf.sprintf "[%d]" index
        in
        Printf.sprintf "invalid %s%s root %S: %s" field index spelling reason
    | Broad_root { field; path } ->
        if String.equal field "sandbox.writable_roots" then
          Printf.sprintf "%s root %s is too broad; choose a narrower directory"
            field (Spice_path.Abs.to_string path)
        else
          Printf.sprintf
            "%s root %s is too broad; choose sandbox.read=all explicitly"
            field (Spice_path.Abs.to_string path)
    | Redundant_readable_roots ->
        "sandbox.readable_roots is redundant when sandbox.read=all; remove it"

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Status = struct
  type origin = Flag | Config | Default
  type network = Restricted | Enabled | External

  type t = {
    mode : Mode.t;
    read : Read.t;
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

(* Network applies to both confined modes: read-only and workspace-write can
   each opt into outbound access without becoming unconfined. Unconfined and
   declared-external already own network by construction. *)
let sandbox_of_mode ~read ~readable ~environment ~writable ~protect ~network =
  let reads =
    match read with
    | Read.All -> Spice_sandbox.Policy.All
    | Read.Project -> Spice_sandbox.Policy.Only readable
  in
  function
  | Mode.Read_only ->
      Spice_sandbox.Policy.confined ~reads ~writable_roots:[]
        ~protected_paths:[] ~network ~environment
  | Mode.Workspace_write ->
      Spice_sandbox.Policy.confined ~reads ~writable_roots:writable
        ~protected_paths:protect ~network ~environment
  | Mode.Danger_full_access -> Spice_sandbox.Policy.direct ~environment
  | Mode.External_sandbox -> Spice_sandbox.Policy.external_ ~environment

module Effective = struct
  type t = {
    mode : Mode.t;
    read : Read.t;
    roots : (root_origin * Spice_path.Abs.t) list;
    origin : Status.origin;
    require : Require.t;
    policy : Spice_sandbox.Policy.t;
    backend : Spice_sandbox.Backend.t;
    sandbox : Spice_sandbox.t;
  }

  let policy t = t.policy
  let read t = t.read
  let roots t = t.roots
  let readable_roots t =
    match Spice_sandbox.Policy.reads t.policy with
    | Some (Spice_sandbox.Policy.Only roots) -> roots
    | Some Spice_sandbox.Policy.All | None -> []
  let backend t = t.backend
  let writable_roots t = Spice_sandbox.Policy.writable_roots t.policy
  let protected_paths t = Spice_sandbox.Policy.protected_paths t.policy
  let environment_names t =
    Spice_sandbox.Policy.environment t.policy
    |> Spice_sandbox.Environment.names
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
      read = t.read;
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

let root_error ?index ~field ~spelling reason =
  Resolve_error.Invalid_root { field; index; spelling; reason }

(* Expand a leading [~] only against [$HOME]. User-name expansion and relative
   roots are intentionally not ambient shell behavior. *)
let abs_of_config_path ~field ?index ~env spelling =
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
  | None ->
      Error (root_error ?index ~field ~spelling "HOME is not available")
  | Some path ->
      Spice_path.Abs.of_string path
      |> Result.map_error (fun error ->
          root_error ?index ~field ~spelling (Spice_path.Error.message error))

let physical_root ~field ?index ~spelling ~directory path =
  let path_string = Spice_path.Abs.to_string path in
  match Unix.stat path_string with
  | stats
    when stats.Unix.st_kind = Unix.S_DIR
         || ((not directory) && stats.Unix.st_kind = Unix.S_REG) -> (
      match Unix.realpath path_string |> Spice_path.Abs.of_string with
      | Ok path -> Ok path
      | Error error ->
          Error
            (root_error ?index ~field ~spelling
               (Spice_path.Error.message error)))
  | _ ->
      let expected =
        if directory then "a directory" else "a file or directory"
      in
      Error (root_error ?index ~field ~spelling ("expected " ^ expected))
  | exception Unix.Unix_error (error, _, _) ->
      Error
        (root_error ?index ~field ~spelling (Unix.error_message error))

let proper_ancestor ~ancestor path =
  (not (Spice_path.Abs.equal ancestor path))
  && Option.is_some (Spice_path.Abs.relativize ~root:ancestor path)

let broad_root ~env ~workspace_roots path =
  let root = Spice_path.Abs.of_string_exn "/" in
  Spice_path.Abs.equal path root
  || List.exists (proper_ancestor ~ancestor:path) workspace_roots
  ||
  match env "HOME" with
  | None -> false
  | Some home -> (
      match Spice_path.Abs.of_string home with
      | Error _ -> false
      | Ok home -> Spice_path.Abs.equal path (canonical home))

let user_root ~field ?index ~directory ~env ~workspace_roots spelling =
  let ( let* ) = Result.bind in
  let* path = abs_of_config_path ~field ?index ~env spelling in
  let* path = physical_root ~field ?index ~spelling ~directory path in
  if broad_root ~env ~workspace_roots path then
    Error (Resolve_error.Broad_root { field; path })
  else Ok path

let user_roots ~field ~directory ~env ~workspace_roots spellings =
  let rec loop index roots = function
    | [] -> Ok (List.rev roots)
    | spelling :: rest ->
        let ( let* ) = Result.bind in
        let* root =
          user_root ~field ~index ~directory ~env ~workspace_roots spelling
        in
        loop (index + 1) (root :: roots) rest
  in
  loop 0 [] spellings

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

let trusted_workspace_executable_roots workspace =
  Spice_workspace.roots workspace
  |> List.filter_map (fun root ->
      let candidate =
        Filename.concat
          (Spice_workspace.Root.dir root |> Spice_path.Abs.to_string)
          "_opam/bin"
      in
      match Unix.stat candidate with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
          Spice_path.Abs.of_string candidate |> Result.to_option
          |> Option.map canonical
      | _ -> None
      | exception Unix.Unix_error _ -> None)

let canonical_paths paths = List.sort_uniq Spice_path.Abs.compare paths

let root_paths paths =
  let paths = canonical_paths paths in
  List.filter
    (fun path ->
      not
        (List.exists
           (fun candidate -> proper_ancestor ~ancestor:candidate path)
           paths))
    paths

let unique_paths paths =
  List.fold_left
    (fun unique path ->
      if List.exists (Spice_path.Abs.equal path) unique then unique
      else unique @ [ path ])
    [] paths

let existing_auto_root path =
  match Spice_path.Abs.of_string path with
  | Error _ -> None
  | Ok path -> (
      match Unix.stat (Spice_path.Abs.to_string path) with
      | { Unix.st_kind = (Unix.S_DIR | Unix.S_REG); _ } -> Some (canonical path)
      | _ -> None
      | exception Unix.Unix_error _ -> None)

let platform_roots ~env ~workspace_roots =
  let candidates =
    if is_linux () then
      [
        "/bin";
        "/sbin";
        "/usr";
        "/etc";
        "/lib";
        "/lib64";
        "/nix/store";
        "/run/current-system/sw";
      ]
    else
      [
        "/bin";
        "/sbin";
        "/usr/bin";
        "/usr/sbin";
        "/usr/lib";
        "/usr/libexec";
        "/usr/share";
        "/System/Library";
        "/System/iOSSupport/System/Library";
        "/Library/Apple/System/Library";
        "/Library/Apple/usr/lib";
        "/Library/Filesystems/NetFSPlugins";
        "/Library/Preferences";
        "/opt/homebrew";
        "/usr/local/Cellar";
        "/usr/local/opt";
        "/usr/local/lib";
        "/usr/local/share";
        "/private/etc";
        "/private/var/db";
      ]
  in
  let roots =
    List.concat_map
      (fun spelling ->
        match Spice_path.Abs.of_string spelling with
        | Error _ -> []
        | Ok lexical -> (
            match Unix.stat spelling with
            | { Unix.st_kind = (Unix.S_DIR | Unix.S_REG); _ } ->
                let physical = canonical lexical in
                if Spice_path.Abs.equal lexical physical then [ lexical ]
                else [ lexical; physical ]
            | _ -> []
            | exception Unix.Unix_error _ -> []))
      candidates
  in
  match
    List.find_opt (broad_root ~env ~workspace_roots) roots
  with
  | None -> Ok roots
  | Some path -> Error (Resolve_error.Broad_root { field = "platform"; path })

let path_roots ~scoped ~env ~workspace_roots =
  let value = Option.value (env "PATH") ~default:"" in
  let segments = String.split_on_char ':' value in
  let rec loop index roots = function
    | [] -> Ok (List.rev roots)
    | segment :: rest -> (
        match Spice_path.Abs.of_string segment with
        | Error error ->
            Error
              (root_error ~index ~field:"PATH" ~spelling:segment
                 (Spice_path.Error.message error))
        | Ok path -> (
            let spelling = Spice_path.Abs.to_string path in
            match Unix.stat spelling with
            | { Unix.st_kind = Unix.S_DIR; _ } ->
                let path = canonical path in
                if scoped && broad_root ~env ~workspace_roots path then
                  Error (Resolve_error.Broad_root { field = "PATH"; path })
                else loop (index + 1) (path :: roots) rest
            | _ ->
                Error
                  (root_error ~index ~field:"PATH" ~spelling
                     "expected a directory")
            | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                loop (index + 1) roots rest
            | exception Unix.Unix_error (error, _, _) ->
                Error
                  (root_error ~index ~field:"PATH" ~spelling
                     (Unix.error_message error))))
  in
  loop 0 [] segments

let toolchain_roots ~env ~workspace_roots =
  let variables =
    [
      ("CAML_LD_LIBRARY_PATH", true);
      ("OCAMLPATH", true);
      ("OCAML_TOPLEVEL_PATH", false);
      ("OPAM_SWITCH_PREFIX", false);
      ("OCAMLLIB", false);
      ("DUNE_OCAML_STDLIB", false);
    ]
  in
  let rec add_values name index roots = function
    | [] -> Ok roots
    | spelling :: rest -> (
        match Spice_path.Abs.of_string spelling with
        | Error error ->
            Error
              (root_error ~index ~field:name ~spelling
                 (Spice_path.Error.message error))
        | Ok path -> (
            match Unix.stat spelling with
            | { Unix.st_kind = Unix.S_DIR; _ } ->
                let path = canonical path in
                if broad_root ~env ~workspace_roots path then
                  Error (Resolve_error.Broad_root { field = name; path })
                else add_values name (index + 1) ((name, path) :: roots) rest
            | _ ->
                Error
                  (root_error ~index ~field:name ~spelling
                     "expected a directory")
            | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                add_values name (index + 1) roots rest
            | exception Unix.Unix_error (error, _, _) ->
                Error
                  (root_error ~index ~field:name ~spelling
                     (Unix.error_message error))))
  in
  let rec loop roots = function
    | [] -> Ok roots
    | (name, list) :: rest ->
        let values =
          match env name with
          | None -> []
          | Some value when list -> String.split_on_char ':' value
          | Some value -> [ value ]
        in
        let* roots = add_values name 0 roots values in
        loop roots rest
  in
  loop [] variables

let opam_bin_root ~env toolchain_roots =
  match
    List.find_opt
      (fun (name, _) -> String.equal name "OPAM_SWITCH_PREFIX")
      toolchain_roots
  with
  | Some (_, prefix) -> (
      match Spice_path.Abs.add_component prefix "bin" with
      | Error _ -> None
      | Ok path -> existing_auto_root (Spice_path.Abs.to_string path))
  | None -> (
      match env "OPAM_SWITCH_PREFIX" with
      | None -> None
      | Some prefix -> existing_auto_root (Filename.concat prefix "bin"))

let environment_path ~scoped ~workspace_trusted ~path_roots ~toolchain_roots
    ~env ~workspace =
  let trusted =
    if workspace_trusted then trusted_workspace_executable_roots workspace
    else []
  in
  let admitted = trusted @ Option.to_list (opam_bin_root ~env toolchain_roots) in
  let paths =
    if scoped then
      admitted @ path_roots |> unique_paths
      |> List.map Spice_path.Abs.to_string
    else
      List.map Spice_path.Abs.to_string admitted
      @ Option.to_list (env "PATH")
  in
  String.concat ":" paths

let existing_entry root name =
  match Spice_path.Abs.add_component root name with
  | Error _ -> None
  | Ok path -> (
      match Unix.lstat (Spice_path.Abs.to_string path) with
      | _ -> Some path
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
      | exception Unix.Unix_error _ -> None)

let workspace_protected_paths workspace =
  Spice_workspace.roots workspace
  |> List.concat_map (fun root ->
      let root = Spice_workspace.Root.dir root in
      List.filter_map (existing_entry root) [ ".git"; ".spice" ])

let read_metadata_path ~field path =
  let spelling = Spice_path.Abs.to_string path in
  match open_in_bin spelling with
  | input ->
      Fun.protect
        ~finally:(fun () -> close_in input)
        (fun () ->
          let length = in_channel_length input in
          if length > 4096 then
            Error (root_error ~field ~spelling "metadata file is too large")
          else
            let value = really_input_string input length |> String.trim in
            if String.equal value "" || String.contains value '\n'
               || String.contains value '\r'
            then Error (root_error ~field ~spelling "expected exactly one line")
            else Ok value)
  | exception Sys_error reason -> Error (root_error ~field ~spelling reason)

let resolve_metadata_dir ~field ~env ~workspace_roots ~base spelling =
  let ( let* ) = Result.bind in
  let* path =
    Spice_path.Abs.resolve_any ~base spelling
    |> Result.map_error (fun error ->
        root_error ~field ~spelling (Spice_path.Error.message error))
  in
  let* path = physical_root ~field ~spelling ~directory:true path in
  if broad_root ~env ~workspace_roots path then
    Error (Resolve_error.Broad_root { field; path })
  else Ok path

let linked_git_roots ~env ~workspace_roots =
  let rec loop roots = function
    | [] -> Ok (List.rev roots)
    | workspace_root :: rest -> (
        match Spice_path.Abs.add_component workspace_root ".git" with
        | Error _ -> loop roots rest
        | Ok git -> (
            let spelling = Spice_path.Abs.to_string git in
            match Unix.lstat spelling with
            | { Unix.st_kind = Unix.S_DIR; _ } -> loop roots rest
            | { Unix.st_kind = Unix.S_REG; _ } ->
                let* line = read_metadata_path ~field:"workspace .git" git in
                let prefix = "gitdir: " in
                if not (String.starts_with ~prefix line) then
                  Error
                    (root_error ~field:"workspace .git" ~spelling
                       "expected a gitdir line")
                else
                  let target =
                    String.sub line (String.length prefix)
                      (String.length line - String.length prefix)
                  in
                  let* gitdir =
                    resolve_metadata_dir ~field:"workspace gitdir" ~env
                      ~workspace_roots ~base:workspace_root target
                  in
                  let* roots =
                    match Spice_path.Abs.add_component gitdir "commondir" with
                    | Error _ -> Ok (gitdir :: roots)
                    | Ok commondir -> (
                        match Unix.lstat (Spice_path.Abs.to_string commondir) with
                        | { Unix.st_kind = Unix.S_REG; _ } ->
                            let* target =
                              read_metadata_path ~field:"workspace commondir"
                                commondir
                            in
                            let* common =
                              resolve_metadata_dir
                                ~field:"workspace common git directory" ~env
                                ~workspace_roots ~base:gitdir target
                            in
                            Ok (common :: gitdir :: roots)
                        | _ -> Ok (gitdir :: roots)
                        | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                            Ok (gitdir :: roots)
                        | exception Unix.Unix_error (error, _, _) ->
                            Error
                              (root_error ~field:"workspace commondir"
                                 ~spelling:(Spice_path.Abs.to_string commondir)
                                 (Unix.error_message error)))
                  in
                  loop roots rest
            | _ ->
                Error
                  (root_error ~field:"workspace .git" ~spelling
                     "expected a directory or gitfile")
            | exception Unix.Unix_error (Unix.ENOENT, _, _) -> loop roots rest
            | exception Unix.Unix_error (error, _, _) ->
                Error
                  (root_error ~field:"workspace .git" ~spelling
                     (Unix.error_message error))))
  in
  loop [] workspace_roots

let resolve_workspace_roots ~read ~env workspace =
  let rec loop index roots = function
    | [] -> Ok (List.rev roots)
    | root :: rest ->
        let spelling =
          Spice_workspace.Root.dir root |> Spice_path.Abs.to_string
        in
        let path = Spice_workspace.Root.dir root in
        let ( let* ) = Result.bind in
        let* path =
          physical_root ~field:"workspace" ~index ~spelling ~directory:true path
        in
        if Read.equal read Read.Project
           && broad_root ~env ~workspace_roots:[] path
        then
          Error (Resolve_error.Broad_root { field = "workspace"; path })
        else loop (index + 1) (path :: roots) rest
  in
  loop 0 [] (Spice_workspace.roots workspace)

let resolve ~sw ?flag ?config_mode ?(require = Require.Enforced) ?(protect = [])
    ?(read = Read.All) ?(readable_roots = []) ?(writable_roots = [])
    ?(network = Network.Restricted) ?(workspace_trusted = false) ~stdenv ~env
    ~workspace () =
  let* scratch = create_scratch ~sw ~stdenv ~env in
  let mode, origin =
    match (flag, config_mode) with
    | Some mode, _ -> (mode, Status.Flag)
    | None, Some mode -> (mode, Status.Config)
    | None, None -> (Mode.Workspace_write, Status.Default)
  in
  let* () =
    if Read.equal read Read.All && readable_roots <> [] then
      Error Resolve_error.Redundant_readable_roots
    else Ok ()
  in
  let* workspace_roots = resolve_workspace_roots ~read ~env workspace in
  let* configured_reads =
    user_roots ~field:"sandbox.readable_roots" ~directory:false ~env
      ~workspace_roots
      readable_roots
  in
  let* configured_writes =
    user_roots ~field:"sandbox.writable_roots" ~directory:true ~env
      ~workspace_roots
      writable_roots
  in
  let scoped = Read.equal read Read.Project in
  let* executable_roots = path_roots ~scoped ~env ~workspace_roots in
  let* toolchain_roots =
    if scoped then toolchain_roots ~env ~workspace_roots else Ok []
  in
  let* platform_roots =
    if scoped then platform_roots ~env ~workspace_roots else Ok []
  in
  let* git_roots =
    if scoped then linked_git_roots ~env ~workspace_roots else Ok []
  in
  let toolchain_paths = List.map snd toolchain_roots in
  let environment_path =
    environment_path ~scoped ~workspace_trusted ~path_roots:executable_roots
      ~toolchain_roots ~env ~workspace
  in
  let* environment =
    Spice_sandbox.Environment.make ~path:environment_path ~scratch
      ~user_names:[] ~launch:env
    |> Result.map_error (fun error -> Resolve_error.Invalid_environment error)
  in
  let readable =
    if scoped then
      root_paths
        (workspace_roots @ configured_reads @ platform_roots @ executable_roots
       @ toolchain_paths @ git_roots)
    else []
  in
  let writable = workspace_roots @ configured_writes |> root_paths in
  let protect =
    List.filter_map
      (fun path ->
        existing_auto_root (Spice_path.Abs.to_string path))
      protect
    @ workspace_protected_paths workspace
    @ git_roots
    |> canonical_paths
  in
  let policy =
    sandbox_of_mode ~read ~readable ~environment ~writable ~protect ~network
      mode
  in
  let backend = host_backend ~stdenv ~env in
  let sandbox = Spice_sandbox.seal ~backend policy in
  let roots =
    if scoped then
      List.map (fun path -> Workspace, path) workspace_roots
      @ List.map (fun path -> User_configured, path) configured_reads
      @ List.map (fun path -> Platform, path) platform_roots
      @ List.map (fun path -> Executable "PATH", path) executable_roots
      @ List.map (fun (name, path) -> Toolchain name, path) toolchain_roots
      @ List.map (fun path -> Git_worktree, path) git_roots
      @ [ Scratch, scratch ]
    else [ Scratch, scratch ]
  in
  let effective_roots =
    match Spice_sandbox.Policy.reads policy with
    | Some (Spice_sandbox.Policy.Only roots) -> roots
    | Some Spice_sandbox.Policy.All | None -> [ scratch ]
  in
  let roots =
    List.fold_left
      (fun facts ((_, path) as fact) ->
        if
          (not (List.exists (Spice_path.Abs.equal path) effective_roots))
          || List.exists (fun (_, seen) -> Spice_path.Abs.equal path seen) facts
        then facts
        else facts @ [ fact ])
      [] roots
  in
  Ok { Effective.mode; read; roots; origin; require; policy; backend; sandbox }

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
