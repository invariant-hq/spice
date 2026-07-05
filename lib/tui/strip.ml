(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* The strip's own glyphs (01-transcript.md §The status strip): the verbose lens
   fisheye and the queued-prompt up-arrow. Theme.ml does not carry them yet and
   is co-owned, so they live here as local constants until the vocabulary
   absorbs them. *)
let verbose_glyph = "◎"
let queued_glyph = "↥"

(* Each strip row is a full-width single line indented two columns — the
   transient-chrome margin above the composer, matching the notice grammar's
   flat indent-2 (01-transcript.md §Base grammar). *)
let row children =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~padding:(padding_lrtb 2 0 0 0)
    ~size:{ width = pct 100; height = px 1 }
    children

let first_line prompt =
  match String.index_opt prompt '\n' with
  | Some i -> String.sub prompt 0 i
  | None -> prompt

(* Pre-truncate in OCaml (the flex-truncate quirk, project memory): the prompt
   is clipped to what remains after the marker, quotes, and the [(↑ edits)] hint,
   so the row never wraps. *)
let queued_row ~width prompt =
  let budget = max 8 (width - 27) in
  let line = first_line prompt in
  let shown =
    if String.length line <= budget then line
    else
      (* Walk the byte budget back over UTF-8 continuation bytes so the cut
         never splits a scalar (the queued prompt is arbitrary Unicode). *)
      let rec cut i =
        if i > 0 && Char.code line.[i] land 0xC0 = 0x80 then cut (i - 1) else i
      in
      String.sub line 0 (cut (budget - 1)) ^ "…"
  in
  row
    [
      text ~style:Theme.muted ~wrap:`None ~flex_shrink:0.
        (queued_glyph ^ " queued" ^ Theme.separator ^ "\"" ^ shown ^ "\"");
      text ~style:Theme.faint ~wrap:`None " (↑ edits)";
    ]

let verbose_row =
  row
    [
      text ~style:Theme.warning ~wrap:`None ~flex_shrink:0.
        (verbose_glyph ^ " verbose");
      text ~style:Theme.faint ~wrap:`None " ctrl+o closes";
    ]

let view ~width ~verbose ~queued =
  (if verbose then [ verbose_row ] else [])
  @ List.map (queued_row ~width) queued
