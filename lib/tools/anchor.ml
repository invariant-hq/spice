(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module W = Spice_workspace

type t = string

let equal = String.equal
let to_string t = t

let of_string s =
  if String.equal s "" then
    invalid_arg "Spice_tools.Anchor.of_string: empty anchor"
  else s

let deterministic_line ~path ~number ~text =
  Spice_digest.key ~length:12 ~domain:"spice.tools.anchor.line.v1"
    [ W.Path.display path; string_of_int number; text ]

module Source = struct
  type anchor = t
  type t = path:W.Path.t -> number:int -> text:string -> anchor option

  let make f = f
  let none = make (fun ~path:_ ~number:_ ~text:_ -> None)

  let deterministic =
    make (fun ~path ~number ~text ->
        Some (deterministic_line ~path ~number ~text))

  let line t ~path ~number ~text = t ~path ~number ~text
end

module Resolver = struct
  type error =
    | Not_found of { anchor : string }
    | Mismatch of { anchor : string; expected : string; provided : string }

  type t = {
    reconcile : path:W.Path.t -> lines:string list -> unit;
    resolve :
      path:W.Path.t -> anchor:string -> expected:string -> (int, error) result;
    source : Source.t;
  }

  let error_equal (a : error) (b : error) =
    match (a, b) with
    | Not_found a, Not_found b -> String.equal a.anchor b.anchor
    | Mismatch a, Mismatch b ->
        String.equal a.anchor b.anchor
        && String.equal a.expected b.expected
        && String.equal a.provided b.provided
    | (Not_found _ | Mismatch _), _ -> false

  let error_message (error : error) =
    match error with
    | Not_found { anchor } ->
        Printf.sprintf
          "anchor %S not found in the file; re-read the file to get current \
           anchors and retry"
          anchor
    | Mismatch { anchor; expected; provided } ->
        Printf.sprintf
          "anchor %S exists, but the line text you provided does not match the \
           file's content. Expected: %S, Provided: %S. Re-read the file to get \
           current anchors and retry"
          anchor expected provided

  let pp_error ppf (error : error) =
    match error with
    | Not_found { anchor } ->
        Format.fprintf ppf "@[<hov>Not_found { anchor = %S }@]" anchor
    | Mismatch { anchor; expected; provided } ->
        Format.fprintf ppf
          "@[<hov>Mismatch { anchor = %S; expected = %S; provided = %S }@]"
          anchor expected provided
end
