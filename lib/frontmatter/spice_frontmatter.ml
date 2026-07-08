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

type t = { fields : (string * Yaml.value) list; body : string }

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
          match Yaml.of_string yaml_text with
          | Error (`Msg message) -> Error (Error.Invalid_yaml message)
          | Ok (`O fields) -> Ok { fields; body }
          | Ok (`Null | `Bool _ | `Float _ | `String _ | `A _) ->
              Error Error.Not_a_mapping)

let body t = t.body
let keys t = List.map fst t.fields

let yaml_string = function
  | `String value -> Some value
  | `Null | `Bool _ | `Float _ | `A _ | `O _ -> None

let string key t =
  match List.assoc_opt key t.fields with
  | None -> None
  | Some value -> yaml_string value
