(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t = Unterminated | Invalid_yaml of string | Not_a_mapping

  let message = function
    | Unterminated -> "frontmatter fence has no closing --- line"
    | Invalid_yaml message ->
        Printf.sprintf "invalid frontmatter YAML: %s" message
    | Not_a_mapping -> "frontmatter YAML must be a mapping of keys to values"

  let pp ppf error = Format.pp_print_string ppf (message error)
end

type field_value = String of string | Other

type t = { fields : (string * field_value) list; body : string }

(* [line_end doc start] is the index of the '\n' ending the line starting at
   [start], or the document length for a final line without a newline. *)
let line_end doc start =
  match String.index_from_opt doc start '\n' with
  | Some i -> i
  | None -> String.length doc

let next_line_start doc stop = min (stop + 1) (String.length doc)

let is_fence doc start stop =
  let stop = if stop > start && doc.[stop - 1] = '\r' then stop - 1 else stop in
  stop - start = 3 && String.sub doc start 3 = "---"

let key = function
  | `Scalar { Yaml.value; _ } -> Some value
  | `Alias _ | `A _ | `O _ -> None

let scalar_value scalar =
  match Yaml.to_json (`Scalar scalar) with
  | Ok (`String value) -> String value
  | Ok (`Null | `Bool _ | `Float _ | `A _ | `O _) | Error _ -> Other

let field_value = function
  | `Scalar scalar -> scalar_value scalar
  | `Alias _ | `A _ | `O _ -> Other

let fields members =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (yaml_key, yaml_value) :: members -> (
        match key yaml_key with
        | None -> Error Error.Not_a_mapping
        | Some key -> loop ((key, field_value yaml_value) :: acc) members)
  in
  loop [] members

let parse doc =
  let len = String.length doc in
  let first_end = line_end doc 0 in
  if not (is_fence doc 0 first_end) then Ok { fields = []; body = doc }
  else
    let yaml_start = next_line_start doc first_end in
    let rec find_close start =
      if start >= len then Error Error.Unterminated
      else
        let stop = line_end doc start in
        if is_fence doc start stop then Ok (start, stop)
        else find_close (next_line_start doc stop)
    in
    match find_close yaml_start with
    | Error _ as error -> error
    | Ok (close_start, close_stop) -> (
        let yaml_text = String.sub doc yaml_start (close_start - yaml_start) in
        let body_start = next_line_start doc close_stop in
        let body = String.sub doc body_start (len - body_start) in
        if String.trim yaml_text = "" then Ok { fields = []; body }
        else
          match Yaml.yaml_of_string yaml_text with
          | Error (`Msg message) -> Error (Error.Invalid_yaml message)
          | Ok (`O { Yaml.m_members; _ }) -> (
              match fields m_members with
              | Ok fields -> Ok { fields; body }
              | Error _ as error -> error)
          | Ok (`Scalar _ | `Alias _ | `A _) -> Error Error.Not_a_mapping)

let body t = t.body
let keys t = List.map fst t.fields

let string key t =
  match List.assoc_opt key t.fields with
  | None -> None
  | Some (String value) -> Some value
  | Some Other -> None
