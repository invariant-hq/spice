(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Conversions into {!Spice_ocaml} positions and ranges.

    The OCaml tools recover source locations from two sources: compiler
    [Lexing.position]/[Location.t] values (via [compiler-libs]) and merlin JSON
    [{line, col}] objects. This module holds the one converter of each so the
    arithmetic and validation are not re-derived per tool. It lives in
    [spice_tools] rather than {!Spice_ocaml} core because the range converter
    needs [compiler-libs], which core deliberately excludes. *)

val of_lexing : Lexing.position -> Spice_ocaml.Position.t
(** [of_lexing p] is [p] as a source position. Lines are 1-based; the column is
    the in-line byte offset [pos_cnum - pos_bol]. *)

val range_of_loc : Location.t -> Spice_ocaml.Range.t
(** [range_of_loc loc] is [loc]'s half-open source range, from
    [of_lexing loc.loc_start] to [of_lexing loc.loc_end]. *)

val of_json : Jsont.json -> (Spice_ocaml.Position.t, string) result
(** [of_json json] decodes a merlin [{"line": l, "col": c}] object into a source
    position.

    It is [Ok position] when [json] has integer [line] and [col] members that
    form a valid position, [Error message] with the position validation message
    when they are out of range, and
    [Error "position object must contain line and col"] when either member is
    absent or not an integer. *)
