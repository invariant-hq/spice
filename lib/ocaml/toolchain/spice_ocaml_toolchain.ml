(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let path_separator = if String.equal Sys.os_type "Win32" then ';' else ':'

let non_empty = function Some value when value <> "" -> Some value | _ -> None

let bin_dir ~lookup =
  match non_empty (lookup "DUNE_OCAML_STDLIB") with
  | Some stdlib ->
      (* [DUNE_OCAML_STDLIB] is [<prefix>/lib/ocaml]; two [dirname]s reach the
         switch prefix whose [bin] holds dune, ocaml, and ocamlmerlin. *)
      Some (Filename.concat (Filename.dirname (Filename.dirname stdlib)) "bin")
  | None -> (
      match non_empty (lookup "OPAM_SWITCH_PREFIX") with
      | Some prefix -> Some (Filename.concat prefix "bin")
      | None -> None)

let path_dirs path =
  String.split_on_char path_separator path
  |> List.filter (fun dir -> not (String.equal dir ""))

let resolve_on_path ~path program =
  List.find_map
    (fun dir ->
      let candidate = Filename.concat dir program in
      match Unix.access candidate [ Unix.X_OK ] with
      | () -> Some candidate
      | exception Unix.Unix_error _ -> None)
    (path_dirs path)

let resolves_on_path ~path program =
  Option.is_some (resolve_on_path ~path program)

let prepend dir = function
  | None | Some "" -> dir
  | Some path -> dir ^ String.make 1 path_separator ^ path

(* The [PATH] value to hand a child so [program] resolves, or [None] to leave it
   as-is: [None] both when [program] already resolves and when nothing can be
   recovered — either way [PATH] should not change. *)
let path_for ~path ~lookup ~program =
  let resolves =
    match path with None -> false | Some path -> resolves_on_path ~path program
  in
  if resolves then None
  else match bin_dir ~lookup with None -> None | Some dir -> Some (prepend dir path)

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

let augment env ~program =
  match path_for ~path:(env_lookup env "PATH") ~lookup:(env_lookup env) ~program with
  | None -> env
  | Some path ->
      let entry = "PATH=" ^ path in
      if
        Array.exists (fun binding -> String.equal (binding_name binding) "PATH") env
      then
        Array.map
          (fun binding ->
            if String.equal (binding_name binding) "PATH" then entry else binding)
          env
      else Array.append [| entry |] env

let unreachable_hint ~program =
  Printf.sprintf
    "%s is not on Spice's PATH. Spice inherits the PATH of the process that \
     launched it; a shell may expose %s only through an alias or a hook that \
     child processes do not inherit. Relaunch Spice from a shell where `command \
     -v %s` prints a real path (for example after `eval $(opam env)`), or add the \
     opam switch bin directory to PATH."
    program program program

let locate env ~program =
  let env = augment env ~program in
  let exe =
    if not (String.equal (Filename.basename program) program) then None
    else
      match env_lookup env "PATH" with
      | None -> None
      | Some path -> resolve_on_path ~path program
  in
  (env, exe)
