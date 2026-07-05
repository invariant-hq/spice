(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let of_lexing (position : Lexing.position) =
  Spice_ocaml.Position.make ~line:position.Lexing.pos_lnum
    ~column:(position.Lexing.pos_cnum - position.Lexing.pos_bol)

let range_of_loc (loc : Location.t) =
  Spice_ocaml.Range.make
    ~start:(of_lexing loc.Warnings.loc_start)
    ~end_:(of_lexing loc.Warnings.loc_end)

let json_field name json =
  match json with
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let int_field name json =
  match json_field name json with
  | Some value -> (
      match Jsont.Json.decode Jsont.int value with
      | Ok n -> Some n
      | Error _ -> None)
  | None -> None

let of_json json =
  match (int_field "line" json, int_field "col" json) with
  | Some line, Some column -> (
      try Ok (Spice_ocaml.Position.make ~line ~column)
      with Invalid_argument message -> Error message)
  | _ -> Error "position object must contain line and col"
