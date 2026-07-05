(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { query : string; selected : int }
type activation = Run of Command.t | Insert of string

let make = { query = ""; selected = 0 }

(* The composer's text is the filter, so matches are derived from the query
   every time rather than cached — no state can drift from the draft. *)
let matches t = Command.filter ~query:t.query
let clamp lo hi x = if x < lo then lo else if x > hi then hi else x

let with_query query t =
  let count = List.length (Command.filter ~query) in
  let selected =
    if String.equal query t.query then clamp 0 (max 0 (count - 1)) t.selected
    else 0
  in
  { query; selected }

let selected_command t = List.nth_opt (matches t) t.selected

let move dir t =
  let count = List.length (matches t) in
  if count = 0 then t
  else
    let step = match dir with `Up -> -1 | `Down -> 1 in
    { t with selected = (((t.selected + step) mod count) + count) mod count }

let activate t =
  match selected_command t with
  | None -> None
  | Some c -> (
      match Command.argument_hint c with
      | None -> Some (Run c)
      | Some _ -> Some (Insert (Command.slash c ^ " ")))

let common_prefix a b =
  let n = min (String.length a) (String.length b) in
  let rec loop i =
    if i < n && Char.equal a.[i] b.[i] then loop (i + 1) else i
  in
  String.sub a 0 (loop 0)

let complete t =
  match matches t with
  | [] -> None
  | first :: rest ->
      let lcp =
        List.fold_left
          (fun acc c -> common_prefix acc (Command.slash c))
          (Command.slash first) rest
      in
      (* Only offer a completion that adds characters to the typed token; the
         common prefix always contains the query, so the matches survive it. *)
      if String.length lcp > String.length t.query + 1 then Some lcp else None

let pad_right n s = s ^ String.make (max 0 (n - String.length s)) ' '

let truncate_tail ~width s =
  if width <= 0 then ""
  else if String.length s <= width then s
  else if width = 1 then "…"
  else String.sub s 0 (width - 1) ^ "…"

(* A palette row's content (the cursor column is Completion_list's): the padded
   slash (accent when selected), the muted description truncated to what is left
   after the cursor, slash column, and hint, then the faint argument hint. *)
let row ~width ~slash_col ~selected c =
  let slash_style = if selected then Some Theme.accent else None in
  let hint = Command.argument_hint c in
  let hint_width =
    match hint with Some h -> 2 + String.length h | None -> 0
  in
  let desc_width = width - 2 - slash_col - 2 - hint_width in
  let description =
    truncate_tail ~width:(max 0 desc_width) (Command.description c)
  in
  Completion_list.segment ?style:slash_style
    (pad_right slash_col (Command.slash c))
  :: Completion_list.segment ~style:Theme.muted ("  " ^ description)
  ::
  (match hint with
  | Some h -> [ Completion_list.segment ~style:Theme.faint ("  " ^ h) ]
  | None -> [])

let view ~width t =
  match matches t with
  | [] -> Completion_list.note "no matching commands"
  | ms ->
      let slash_col =
        List.fold_left (fun w c -> max w (String.length (Command.slash c))) 0 ms
      in
      let rows =
        List.mapi
          (fun i c -> row ~width ~slash_col ~selected:(i = t.selected) c)
          ms
      in
      Completion_list.view ~selected:t.selected rows
