(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  id : Spice_session.Id.t;
  title : string option;
  preview : string option;
  lifecycle : Spice_session.Metadata.Status.t;
  phase : Spice_session.State.Phase.t;
  event_count : int;
  turns : int;
  active_turn : Spice_session.Turn.Id.t option;
  cwd : Spice_path.Abs.t;
  forked_from : Spice_session.Metadata.Forked_from.t option;
  created_at : Spice_session.Time.t;
  updated_at : Spice_session.Time.t;
  revision : Spice_session.Revision.t option;
}

(* Pure text normalization for user-prompt-derived previews and search keys,
   inlined so the projection carries no dependency beyond the session vocabulary. *)

let is_space = function ' ' | '\n' | '\r' | '\t' | '\012' -> true | _ -> false

let collapse_whitespace text =
  let len = String.length text in
  let buffer = Buffer.create len in
  let rec skip_spaces index =
    if index < len && is_space text.[index] then skip_spaces (index + 1)
    else index
  in
  let rec loop index pending_space =
    if index >= len then ()
    else if is_space text.[index] then loop (skip_spaces index) true
    else begin
      if pending_space && Buffer.length buffer > 0 then
        Buffer.add_char buffer ' ';
      Buffer.add_char buffer text.[index];
      loop (index + 1) false
    end
  in
  loop (skip_spaces 0) false;
  Buffer.contents buffer

let utf8_boundary text index =
  let rec loop index =
    if index <= 0 then 0
    else
      let code = Char.code text.[index] in
      if code land 0b1100_0000 = 0b1000_0000 then loop (index - 1) else index
  in
  loop (min index (String.length text))

let truncate ~max_bytes text =
  if String.length text <= max_bytes then text
  else String.sub text 0 (utf8_boundary text max_bytes)

let truncate_preview text =
  let max_bytes = 80 in
  if String.length text <= max_bytes then text
  else truncate ~max_bytes text ^ "\226\128\166"

let preview_of_session session =
  Spice_session.State.turns (Spice_session.state session)
  |> List.find_map (fun turn ->
      match
        Spice_session.Turn.input turn
        |> Spice_session.Turn.Input.text
        |> Option.map collapse_whitespace
      with
      | None | Some "" -> None
      | Some text -> Some (truncate_preview text))

let of_session ?revision session =
  let metadata = Spice_session.metadata session in
  let state = Spice_session.state session in
  {
    id = Spice_session.id session;
    title = Spice_session.Metadata.title metadata;
    preview = preview_of_session session;
    lifecycle = Spice_session.Metadata.status metadata;
    phase = Spice_session.State.phase state;
    event_count = List.length (Spice_session.events session);
    turns = List.length (Spice_session.State.turns state);
    active_turn = Spice_session.State.active_turn_id state;
    cwd = Spice_session.Metadata.cwd metadata;
    forked_from = Spice_session.Metadata.fork metadata;
    created_at = Spice_session.Metadata.created_at metadata;
    updated_at = Spice_session.Metadata.updated_at metadata;
    revision;
  }

let display_title t =
  match t.title with
  | Some title -> title
  | None -> Spice_session.Id.to_string t.id

let search_key t =
  [
    Some (Spice_session.Id.to_string t.id);
    t.title;
    t.preview;
    Some (Spice_path.Abs.to_string t.cwd);
  ]
  |> List.filter_map Fun.id |> String.concat " " |> collapse_whitespace
