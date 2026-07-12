(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type name_reason = Empty | Contains_nul | Contains_equals
  type path_reason = Missing | Empty_segment | Relative_segment | Malformed_segment

  type t =
    | Invalid_name of { name : string; reason : name_reason }
    | Duplicate_name of string
    | Reserved_name of string
    | Invalid_value of { name : string }
    | Invalid_path of { name : string; index : int option; reason : path_reason }

  let name_reason = function
    | Empty -> "is empty"
    | Contains_nul -> "contains NUL"
    | Contains_equals -> "contains '='"

  let path_reason = function
    | Missing -> "is missing"
    | Empty_segment -> "contains an empty segment"
    | Relative_segment -> "contains a relative segment"
    | Malformed_segment -> "contains a malformed segment"

  let message = function
    | Invalid_name { name; reason } ->
        Printf.sprintf "invalid environment name %S: it %s" name
          (name_reason reason)
    | Duplicate_name name ->
        Printf.sprintf "duplicate environment name %S" name
    | Reserved_name name ->
        Printf.sprintf "environment name %S is owned by the sandbox" name
    | Invalid_value { name } ->
        Printf.sprintf "invalid value for environment variable %S: it contains NUL"
          name
    | Invalid_path { name; index; reason } ->
        let location =
          match index with
          | None -> ""
          | Some index -> Printf.sprintf " at segment %d" (index + 1)
        in
        Printf.sprintf "invalid %s%s: it %s" name location (path_reason reason)

  let pp ppf t = Format.pp_print_string ppf (message t)

  let equal a b =
    match a, b with
    | Invalid_name a, Invalid_name b ->
        String.equal a.name b.name && a.reason = b.reason
    | Duplicate_name a, Duplicate_name b | Reserved_name a, Reserved_name b ->
        String.equal a b
    | Invalid_value a, Invalid_value b -> String.equal a.name b.name
    | Invalid_path a, Invalid_path b ->
        String.equal a.name b.name && a.index = b.index && a.reason = b.reason
    | (Invalid_name _ | Duplicate_name _ | Reserved_name _ | Invalid_value _
      | Invalid_path _), _ ->
        false
end

type t = {
  bindings : (string * string) list;
  scratch : Spice_path.Abs.t;
}

let derived_names = [ "HOME"; "TEMP"; "TMP"; "TMPDIR" ]

let fixed_bindings =
  [
    ("CLICOLOR", "0");
    ("CLICOLOR_FORCE", "0");
    ("GIT_PAGER", "cat");
    ("LESS", "-FRX");
    ("NO_COLOR", "1");
    ("PAGER", "cat");
    ("TERM", "dumb");
  ]

let inherited_names =
  [
    "LANG";
    "LANGUAGE";
    "LC_ALL";
    "LC_COLLATE";
    "LC_CTYPE";
    "LC_MESSAGES";
    "LC_MONETARY";
    "LC_NUMERIC";
    "LC_TIME";
  ]

let single_toolchain_paths =
  [ "DUNE_OCAML_STDLIB"; "OCAMLLIB"; "OCAML_TOPLEVEL_PATH"; "OPAM_SWITCH_PREFIX" ]

let toolchain_path_lists = [ "CAML_LD_LIBRARY_PATH"; "OCAMLPATH" ]

let reserved_names =
  List.sort_uniq String.compare
    ("PATH" :: derived_names @ List.map fst fixed_bindings @ inherited_names
   @ single_toolchain_paths
   @ toolchain_path_lists)

let ( let* ) = Result.bind

let validate_name name =
  if String.equal name "" then
    Error (Error.Invalid_name { name; reason = Error.Empty })
  else if String.contains name '\000' then
    Error (Error.Invalid_name { name; reason = Error.Contains_nul })
  else if String.contains name '=' then
    Error (Error.Invalid_name { name; reason = Error.Contains_equals })
  else Ok ()

let validate_value name value =
  if String.contains value '\000' then Error (Error.Invalid_value { name })
  else Ok value

let path_reason error =
  match error with
  | Spice_path.Error.Empty -> Error.Empty_segment
  | Spice_path.Error.Relative | Spice_path.Error.Absolute -> Error.Relative_segment
  | Spice_path.Error.Malformed_component _ | Spice_path.Error.Escapes_root ->
      Error.Malformed_segment

let normalize_path_list ~name value =
  let segments = String.split_on_char ':' value in
  let rec loop index seen normalized = function
    | [] -> Ok (List.rev normalized)
    | segment :: rest -> (
        match Spice_path.Abs.of_string segment with
        | Error error ->
            Error
              (Error.Invalid_path
                 { name; index = Some index; reason = path_reason error })
        | Ok path ->
            let spelling = Spice_path.Abs.to_string path in
            if List.mem spelling seen then loop (index + 1) seen normalized rest
            else
              loop (index + 1) (spelling :: seen) (spelling :: normalized) rest)
  in
  loop 0 [] [] segments

let normalize_required_path value =
  if String.equal value "" then
    Error
      (Error.Invalid_path
         { name = "PATH"; index = None; reason = Error.Missing })
  else
    let* paths = normalize_path_list ~name:"PATH" value in
    match paths with
    | [] ->
        Error
          (Error.Invalid_path
             { name = "PATH"; index = None; reason = Error.Missing })
    | _ :: _ -> Ok (String.concat ":" paths)

let normalize_single_path ~name value =
  match Spice_path.Abs.of_string value with
  | Ok path -> Ok (Spice_path.Abs.to_string path)
  | Error error ->
      Error
        (Error.Invalid_path
           { name; index = None; reason = path_reason error })

let add_launch_binding ~normalize launch name bindings =
  match launch name with
  | None -> Ok bindings
  | Some value ->
      let* value = validate_value name value in
      let* value = normalize ~name value in
      Ok ((name, value) :: bindings)

let unchanged ~name:_ value = Ok value

let validate_user_names names =
  let rec loop seen = function
    | [] -> Ok ()
    | name :: rest ->
        let* () = validate_name name in
        if List.mem name reserved_names then Error (Error.Reserved_name name)
        else if List.mem name seen then Error (Error.Duplicate_name name)
        else loop (name :: seen) rest
  in
  loop [] names

let add_names ~normalize launch names bindings =
  List.fold_left
    (fun result name ->
      let* bindings = result in
      add_launch_binding ~normalize launch name bindings)
    (Ok bindings) names

let add_optional_names ~normalize launch names bindings =
  List.fold_left
    (fun result name ->
      let* bindings = result in
      match add_launch_binding ~normalize launch name bindings with
      | Ok bindings -> Ok bindings
      | Error (Error.Invalid_value _ | Error.Invalid_path _) -> Ok bindings
      | Error error -> Error error)
    (Ok bindings) names

let make ~path ~scratch ~user_names ~launch =
  let* () = validate_user_names user_names in
  let* path = normalize_required_path path in
  let scratch_value = Spice_path.Abs.to_string scratch in
  let bindings =
    ("PATH", path) :: fixed_bindings
    @ List.map (fun name -> name, scratch_value) derived_names
  in
  let* bindings =
    add_optional_names ~normalize:unchanged launch inherited_names bindings
  in
  let* bindings =
    add_optional_names ~normalize:normalize_single_path launch
      single_toolchain_paths bindings
  in
  let normalize_list ~name value =
    let* paths = normalize_path_list ~name value in
    Ok (String.concat ":" paths)
  in
  let* bindings =
    add_optional_names ~normalize:normalize_list launch toolchain_path_lists
      bindings
  in
  let* bindings = add_names ~normalize:unchanged launch user_names bindings in
  Ok { bindings = List.sort (fun (a, _) (b, _) -> String.compare a b) bindings; scratch }

let bindings t = t.bindings
let names t = List.map fst t.bindings
let scratch t = t.scratch

let equal a b =
  Spice_path.Abs.equal a.scratch b.scratch
  && List.equal
       (fun (an, av) (bn, bv) -> String.equal an bn && String.equal av bv)
       a.bindings b.bindings

let pp_names ppf t =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ", ")
    Format.pp_print_string ppf (names t)
