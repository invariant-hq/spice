(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t =
    | Empty
    | Relative
    | Absolute
    | Escapes_root
    | Malformed_component of string

  let message = function
    | Empty -> "path must not be empty"
    | Relative -> "path must be absolute"
    | Absolute -> "path must be relative"
    | Escapes_root -> "path escapes root"
    | Malformed_component c -> Printf.sprintf "malformed path component %S" c

  let equal a b =
    match (a, b) with
    | Empty, Empty
    | Relative, Relative
    | Absolute, Absolute
    | Escapes_root, Escapes_root ->
        true
    | Malformed_component a, Malformed_component b -> String.equal a b
    | (Empty | Relative | Absolute | Escapes_root | Malformed_component _), _ ->
        false

  let pp ppf error = Format.pp_print_string ppf (message error)
end

let error error = Error error

let has_windows_drive_prefix path =
  String.length path >= 2
  && Char.Ascii.is_letter path.[0]
  && Char.equal path.[1] ':'

let starts_with_slash path =
  (not (String.is_empty path)) && Char.equal path.[0] '/'

let is_relative_absolute_syntax path =
  (* Backslash roots and drive prefixes are not accepted absolute paths, but
     they are still absolute-looking syntax and must not be parsed as relative
     paths. *)
  starts_with_slash path
  || ((not (String.is_empty path)) && Char.equal path.[0] '\\')
  || has_windows_drive_prefix path

let split_components = String.split_all ~sep:"/" ~drop:String.is_empty
let join_components components = String.concat "/" components

let parent_before_last_slash path =
  Option.map (fun index -> String.sub path 0 index) (String.rindex_opt path '/')

let basename_after_last_slash path =
  Option.map
    (fun index -> String.drop_first (index + 1) path)
    (String.rindex_opt path '/')

(* The byte sequence is fully initialized and not used after conversion. *)
let append_with_slash a b =
  let len_a = String.length a in
  let len_b = String.length b in
  let bytes = Bytes.create (len_a + 1 + len_b) in
  Bytes.blit_string a 0 bytes 0 len_a;
  Bytes.set bytes len_a '/';
  Bytes.blit_string b 0 bytes (len_a + 1) len_b;
  Bytes.unsafe_to_string bytes

let is_component_char = function '\000' | '/' | '\\' -> false | _ -> true

let malformed_component component =
  String.is_empty component || String.equal component "."
  || String.equal component ".."
  || has_windows_drive_prefix component
  || not (String.for_all is_component_char component)

let checked_component component =
  if malformed_component component then
    error (Error.Malformed_component component)
  else Ok component

let reach_components ~from ~target =
  let rec common from_components target_components =
    match (from_components, target_components) with
    | from_component :: from_rest, target_component :: target_rest
      when String.equal from_component target_component ->
        common from_rest target_rest
    | _ -> (from_components, target_components)
  in
  let from_rest, target_rest = common from target in
  let ups = List.map (Fun.const "..") from_rest in
  match ups @ target_rest with [] -> "." | path -> join_components path

module Rel = struct
  type t = string

  let root = "."
  let is_root t = String.equal t root

  let append a b =
    if is_root a then b else if is_root b then a else append_with_slash a b

  let parent t =
    if is_root t then None
    else
      match parent_before_last_slash t with
      | None -> Some root
      | Some parent -> Some parent

  let basename t =
    if is_root t then None
    else
      match basename_after_last_slash t with
      | None -> Some t
      | Some basename -> Some basename

  let add_component t component =
    match checked_component component with
    | Error _ as error -> error
    | Ok component -> Ok (append t component)

  let of_component_stack components =
    match List.rev components with
    | [] -> root
    | components -> join_components components

  (* Root-based parsing is the common path. Resolve on a component stack and
     join once to avoid rebuilding an intermediate string at every component. *)
  let resolve_components_from_root input_components =
    let rec loop acc = function
      | [] -> Ok (of_component_stack acc)
      | "" :: components | "." :: components -> loop acc components
      | ".." :: components -> (
          match acc with
          | [] -> error Error.Escapes_root
          | _ :: acc -> loop acc components)
      | component :: components -> (
          match checked_component component with
          | Error _ as error -> error
          | Ok component -> loop (component :: acc) components)
    in
    loop [] input_components

  let resolve_components_from_path start input_components =
    let rec loop t = function
      | [] -> Ok t
      | "" :: components | "." :: components -> loop t components
      | ".." :: components -> (
          match parent t with
          | None -> error Error.Escapes_root
          | Some parent -> loop parent components)
      | component :: components -> (
          match checked_component component with
          | Error _ as error -> error
          | Ok component -> loop (append t component) components)
    in
    loop start input_components

  let resolve_components start input_components =
    if is_root start then resolve_components_from_root input_components
    else resolve_components_from_path start input_components

  let parse_from start path =
    if String.is_empty path then error Error.Empty
    else if is_relative_absolute_syntax path then error Error.Absolute
    else resolve_components start (split_components path)

  let of_string path = parse_from root path

  let invalid_path path error =
    invalid_arg
      (Format.asprintf "Spice_path.Rel.of_string_exn %S: %a" path Error.pp error)

  let of_string_exn path =
    match of_string path with
    | Ok t -> t
    | Error error -> invalid_path path error

  let to_string t = t
  let components t = if is_root t then [] else split_components t
  let is_component component = not (malformed_component component)
  let resolve t path = parse_from t path

  let relativize ~root:prefix t =
    if is_root prefix then Some t
    else if String.equal t prefix then Some root
    else
      let prefix_length = String.length prefix in
      if
        String.length t > prefix_length
        && Char.equal t.[prefix_length] '/'
        && String.starts_with ~prefix t
      then Some (String.drop_first (prefix_length + 1) t)
      else None

  let reach ~from t =
    match relativize ~root:from t with
    | Some suffix -> to_string suffix
    | None -> reach_components ~from:(components from) ~target:(components t)

  let equal = String.equal
  let compare = String.compare
  let hash = String.hash

  module Set = Set.Make (struct
    type nonrec t = t

    let compare = String.compare
  end)

  module Map = Map.Make (struct
    type nonrec t = t

    let compare = String.compare
  end)

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Abs = struct
  type t = string

  let root = "/"
  let is_root t = String.equal t root

  let append_component t component =
    if is_root t then root ^ component else append_with_slash t component

  let parent t =
    if is_root t then None
    else
      match parent_before_last_slash t with
      | None -> None
      | Some "" -> Some root
      | Some parent -> Some parent

  let basename t =
    if is_root t then None
    else
      match basename_after_last_slash t with
      | None -> None
      | Some basename -> Some basename

  let add_component t component =
    match checked_component component with
    | Error _ as error -> error
    | Ok component -> Ok (append_component t component)

  let of_component_stack components =
    match List.rev components with
    | [] -> root
    | components -> root ^ join_components components

  (* Root-based parsing is the common path. Resolve on a component stack and
     join once to avoid rebuilding an intermediate string at every component. *)
  let resolve_components_from_root input_components =
    let rec loop acc = function
      | [] -> Ok (of_component_stack acc)
      | "" :: components | "." :: components -> loop acc components
      | ".." :: components -> (
          (* Lexically, [/..] remains [/]. *)
          match acc with
          | [] -> loop [] components
          | _ :: acc -> loop acc components)
      | component :: components -> (
          match checked_component component with
          | Error _ as error -> error
          | Ok component -> loop (component :: acc) components)
    in
    loop [] input_components

  let resolve_components_from_path start input_components =
    let rec loop t = function
      | [] -> Ok t
      | "" :: components | "." :: components -> loop t components
      | ".." :: components -> (
          (* Lexically, resolving [..] from [/] remains at [/]. *)
          match parent t with
          | None -> loop root components
          | Some parent -> loop parent components)
      | component :: components -> (
          match checked_component component with
          | Error _ as error -> error
          | Ok component -> loop (append_component t component) components)
    in
    loop start input_components

  let resolve_components start input_components =
    if is_root start then resolve_components_from_root input_components
    else resolve_components_from_path start input_components

  let of_string path =
    if String.is_empty path then error Error.Empty
    else if not (starts_with_slash path) then error Error.Relative
    else resolve_components root (split_components path)

  let invalid_path path error =
    invalid_arg
      (Format.asprintf "Spice_path.Abs.of_string_exn %S: %a" path Error.pp error)

  let of_string_exn path =
    match of_string path with
    | Ok t -> t
    | Error error -> invalid_path path error

  let to_string t = t
  let components t = if is_root t then [] else split_components t

  let append_rel t rel =
    if Rel.is_root rel then t
    else if is_root t then root ^ Rel.to_string rel
    else append_with_slash t (Rel.to_string rel)

  let resolve t path =
    if String.is_empty path then error Error.Empty
    else if is_relative_absolute_syntax path then error Error.Absolute
    else resolve_components t (split_components path)

  let resolve_any ~base path =
    if starts_with_slash path then of_string path else resolve base path

  let relativize ~root:prefix t =
    if String.equal t prefix then Some Rel.root
    else if is_root prefix then Some (String.drop_first 1 t)
    else
      let prefix_length = String.length prefix in
      if
        String.length t > prefix_length
        && Char.equal t.[prefix_length] '/'
        && String.starts_with ~prefix t
      then Some (String.drop_first (prefix_length + 1) t)
      else None

  let reach ~from t =
    match relativize ~root:from t with
    | Some suffix -> Rel.to_string suffix
    | None -> reach_components ~from:(components from) ~target:(components t)

  let equal = String.equal
  let compare = String.compare
  let hash = String.hash

  module Set = Set.Make (struct
    type nonrec t = t

    let compare = String.compare
  end)

  module Map = Map.Make (struct
    type nonrec t = t

    let compare = String.compare
  end)

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end
