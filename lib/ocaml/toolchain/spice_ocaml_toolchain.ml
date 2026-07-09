(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let path_separator = if String.equal Sys.os_type "Win32" then ';' else ':'
let non_empty = function Some value when value <> "" -> Some value | _ -> None

module Source = struct
  type t = Explicit | Path | Opam_switch_prefix | Local_switch

  let to_string = function
    | Explicit -> "SPICE_* override"
    | Path -> "PATH"
    | Opam_switch_prefix -> "OPAM_SWITCH_PREFIX"
    | Local_switch -> "local _opam switch"
end

type t = {
  env : string array;
  path : string option;
  (* Recovered toolchain [bin] directories that exist on disk, ladder order. *)
  recovered : (string * Source.t) list;
  (* Raw locator values, kept so diagnostics can say why a rung was empty. *)
  opam_prefix : string option;
  workspace_root : string option;
}

let binding_name binding =
  match String.index_opt binding '=' with
  | Some i -> String.sub binding 0 i
  | None -> binding

let binding_value name binding =
  match String.index_opt binding '=' with
  | Some i when String.equal (String.sub binding 0 i) name ->
      Some (String.sub binding (i + 1) (String.length binding - i - 1))
  | _ -> None

let env_lookup env name = Array.find_map (binding_value name) env

let override_var program =
  let mapped =
    String.map
      (fun c ->
        match c with
        | 'a' .. 'z' -> Char.uppercase_ascii c
        | 'A' .. 'Z' | '0' .. '9' -> c
        | _ -> '_')
      program
  in
  "SPICE_" ^ mapped

(* [Unix.access X_OK] also accepts directories; a toolchain resolution must be
   a runnable file. *)
let executable_file candidate =
  match Unix.access candidate [ Unix.X_OK ] with
  | () -> (
      match Sys.is_directory candidate with
      | true -> false
      | false -> true
      | exception Sys_error _ -> false)
  | exception Unix.Unix_error _ -> false

let path_dirs path =
  String.split_on_char path_separator path
  |> List.filter (fun dir -> not (String.equal dir ""))

let resolve_on_path ~path program =
  List.find_map
    (fun dir ->
      let candidate = Filename.concat dir program in
      if executable_file candidate then Some candidate else None)
    (path_dirs path)

let discover ~env ~workspace_root =
  let lookup name = non_empty (env_lookup env name) in
  let opam_prefix = lookup "OPAM_SWITCH_PREFIX" in
  let existing source = function
    | Some dir when Sys.file_exists dir && Sys.is_directory dir ->
        Some (dir, source)
    | _ -> None
  in
  let recovered =
    List.filter_map Fun.id
      [
        existing Source.Opam_switch_prefix
          (Option.map (fun prefix -> Filename.concat prefix "bin") opam_prefix);
        existing Source.Local_switch
          (Option.map
             (fun root -> Filename.concat (Filename.concat root "_opam") "bin")
             workspace_root);
      ]
  in
  { env; path = lookup "PATH"; recovered; opam_prefix; workspace_root }

let find t program =
  if not (String.equal (Filename.basename program) program) then None
  else
    match non_empty (env_lookup t.env (override_var program)) with
    | Some override ->
        (* Set but unusable never falls through: an explicit choice is not
           silently ignored. *)
        if executable_file override then Some (override, Source.Explicit)
        else None
    | None -> (
        match
          Option.bind t.path (fun path -> resolve_on_path ~path program)
        with
        | Some abs -> Some (abs, Source.Path)
        | None ->
            List.find_map
              (fun (dir, source) ->
                let candidate = Filename.concat dir program in
                if executable_file candidate then Some (candidate, source)
                else None)
              t.recovered)

let prepend_path t dir =
  let path =
    match t.path with
    | None | Some "" -> dir
    | Some path -> dir ^ String.make 1 path_separator ^ path
  in
  let entry = "PATH=" ^ path in
  if
    Array.exists
      (fun binding -> String.equal (binding_name binding) "PATH")
      t.env
  then
    Array.map
      (fun binding ->
        if String.equal (binding_name binding) "PATH" then entry else binding)
      t.env
  else Array.append [| entry |] t.env

let env t ~program =
  match find t program with
  | None | Some (_, Source.Path) -> t.env
  | Some
      (exe, (Source.Explicit | Source.Opam_switch_prefix | Source.Local_switch))
    ->
      prepend_path t (Filename.dirname exe)

(* One clause per rung, in ladder order, saying why it did not resolve
   [program]; shared by {!unreachable_hint} and {!describe}. *)
let checked_summary t ~program =
  let override = override_var program in
  let explicit =
    match non_empty (env_lookup t.env override) with
    | Some value ->
        Printf.sprintf "%s is set to %s but it is not an executable file"
          override value
    | None -> override ^ " unset"
  in
  let path =
    match t.path with
    | None -> "PATH unset"
    | Some _ -> Printf.sprintf "no %s on PATH" program
  in
  let opam =
    match t.opam_prefix with
    | None -> "OPAM_SWITCH_PREFIX unset"
    | Some prefix ->
        Printf.sprintf "no %s under %s" program (Filename.concat prefix "bin")
  in
  let local =
    match t.workspace_root with
    | None -> "no workspace root for a local _opam switch"
    | Some root ->
        Printf.sprintf "no %s under %s" program
          (Filename.concat (Filename.concat root "_opam") "bin")
  in
  String.concat "; " [ explicit; path; opam; local ]

let unreachable_hint t ~program =
  Printf.sprintf
    "%s is not on Spice's PATH. Spice inherits the PATH of the process that \
     launched it; a shell may expose %s only through an alias or a hook that \
     child processes do not inherit. Checked: %s. Relaunch Spice from a shell \
     where `command -v %s` prints a real path (for example after `eval $(opam \
     env)`), or set %s to the executable."
    program program
    (checked_summary t ~program)
    program (override_var program)

let describe t ~program =
  match find t program with
  | Some (exe, source) ->
      Printf.sprintf "%s: %s (via %s)" program exe (Source.to_string source)
  | None ->
      Printf.sprintf "%s: not found (%s)" program (checked_summary t ~program)
