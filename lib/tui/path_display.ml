(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let ellipsis = "…"

let home_relative path =
  let path = Spice_path.Abs.to_string path in
  match Sys.getenv_opt "HOME" with
  | None | Some "" -> path
  | Some home ->
      if String.equal path home then "~"
      else
        let prefix = home ^ Filename.dir_sep in
        if String.starts_with ~prefix path then
          let len = String.length prefix in
          "~/" ^ String.sub path len (String.length path - len)
        else path

(* [segment_start s from] is the index of the earliest ['/'] at or after [from],
   or [String.length s] when none remains. Used to snap an ellipsis cut to a
   segment boundary so the kept tail starts at a whole component. *)
let segment_start s from =
  let n = String.length s in
  let rec scan i =
    if i >= n then n else if s.[i] = '/' then i else scan (i + 1)
  in
  scan (max 0 from)

(* [boundary_at_or_after s i] is the least index at or after [i] that starts a
   whole UTF-8 scalar, so a suffix taken there never opens on a continuation
   byte. [boundary_at_or_before s i] is the greatest such index at or before
   [i], so a prefix cut there never splits a trailing scalar. Cutting a
   byte-budgeted slice on either boundary keeps it valid UTF-8 and no wider. *)
let boundary_at_or_after s i =
  let n = String.length s in
  let rec fwd j =
    if j < n && Char.code s.[j] land 0xC0 = 0x80 then fwd (j + 1) else j
  in
  fwd (max 0 i)

let boundary_at_or_before s i =
  let i = min i (String.length s) in
  let rec back j =
    if j > 0 && Char.code s.[j] land 0xC0 = 0x80 then back (j - 1) else j
  in
  back i

let left_truncate ~width s =
  let n = String.length s in
  if n <= width || width <= 1 then s
  else
    let keep = width - 1 in
    let aligned = segment_start s (n - keep) in
    if aligned < n && n - aligned <= keep then
      ellipsis ^ String.sub s aligned (n - aligned)
    else
      let start = boundary_at_or_after s (n - keep) in
      ellipsis ^ String.sub s start (n - start)

(* [first_segment s] is the leading component kept intact by {!middle_truncate}:
   ["~"] for a home-relative path, ["/root"] for an absolute one, or the whole
   string when it carries no separator. *)
let first_segment s =
  match String.index_opt s '/' with
  | None -> s
  | Some 0 -> (
      match String.index_from_opt s 1 '/' with
      | None -> s
      | Some next -> String.sub s 0 next)
  | Some slash -> String.sub s 0 slash

let middle_truncate ~width s =
  let n = String.length s in
  if n <= width then s
  else
    let head = first_segment s in
    let head_len = String.length head in
    (* Budget the tail after the head and the ellipsis; snap it to a segment
       boundary so the leaf and its parent read cleanly. *)
    let tail_budget = width - head_len - 1 in
    if tail_budget <= 0 then
      (* The leading segment alone overflows [width]; clip it to a whole-scalar
         prefix so the result still fits, rather than returning [head] whole and
         overflowing the budget. *)
      let cut = boundary_at_or_before head (max 0 (width - 1)) in
      String.sub head 0 cut ^ ellipsis
    else
      let aligned = segment_start s (n - tail_budget) in
      let tail =
        if aligned < n && n - aligned <= tail_budget then
          String.sub s aligned (n - aligned)
        else
          let start = boundary_at_or_after s (n - tail_budget) in
          String.sub s start (n - start)
      in
      head ^ ellipsis ^ tail
