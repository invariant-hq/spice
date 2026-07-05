(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Generic-JSON field readers, tolerant of shape: a missing or wrong-typed
   member reads as absence so a malformed line is skipped, never rejected. *)
let json_mem name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let json_string_mem name json =
  match json_mem name json with
  | Some (Jsont.String (text, _)) -> Some text
  | Some _ | None -> None

let json_int_mem name json =
  match json_mem name json with
  | Some (Jsont.Number (number, _)) ->
      if Float.is_integer number then Some (int_of_float number) else None
  | Some _ | None -> None

let json_list_mem name json =
  match json_mem name json with
  | Some (Jsont.Array (items, _)) -> Some items
  | Some _ | None -> None

module Entry = struct
  type t = {
    session : Spice_session.Id.t;
    ts : int;
    draft : Draft.History_entry.t;
  }

  let session t = t.session
  let draft t = t.draft
  let text t = Draft.History_entry.text t.draft

  let of_draft ~session ~ts entry =
    let text = String.trim (Draft.History_entry.text entry) in
    if String.equal text "" then None
    else
      let entry =
        if String.equal text (Draft.History_entry.text entry) then entry
        else Draft.History_entry.of_text text
      in
      Some { session; ts; draft = entry }

  (* Encoding. The [composer.history_entry] object shape and its field spellings
     are shared byte-for-byte with lib/tui/prompt_history.ml — both frontends
     append to one history.jsonl, so this must not fork. *)

  let span_json span =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "start")
          (Jsont.Json.int (Draft.Span.first span));
        Jsont.Json.mem (Jsont.Json.name "end")
          (Jsont.Json.int (Draft.Span.last span));
      ]

  let file_ref_json (span, file_ref) =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "span") (span_json span);
        Jsont.Json.mem (Jsont.Json.name "path")
          (Jsont.Json.string (Draft.File_ref.path file_ref));
        Jsont.Json.mem (Jsont.Json.name "label")
          (Jsont.Json.string (Draft.File_ref.label file_ref));
      ]

  let pending_paste_json (paste : Draft.pending_paste) =
    Jsont.Json.object'
      [
        Jsont.Json.mem
          (Jsont.Json.name "placeholder")
          (Jsont.Json.string paste.Draft.paste_placeholder);
        Jsont.Json.mem (Jsont.Json.name "text")
          (Jsont.Json.string paste.Draft.paste_text);
      ]

  let draft_json draft =
    let fields =
      [
        Jsont.Json.mem (Jsont.Json.name "text")
          (Jsont.Json.string (Draft.History_entry.text draft));
      ]
    in
    let fields =
      match Draft.History_entry.file_refs draft with
      | [] -> fields
      | file_refs ->
          fields
          @ [
              Jsont.Json.mem
                (Jsont.Json.name "file_refs")
                (Jsont.Json.list (List.map file_ref_json file_refs));
            ]
    in
    let fields =
      match Draft.History_entry.pending_pastes draft with
      | [] -> fields
      | pending_pastes ->
          fields
          @ [
              Jsont.Json.mem
                (Jsont.Json.name "pending_pastes")
                (Jsont.Json.list (List.map pending_paste_json pending_pastes));
            ]
    in
    Jsont.Json.object' fields

  let to_json t =
    Jsont.Json.object'
      [
        Jsont.Json.mem (Jsont.Json.name "schema_version") (Jsont.Json.int 1);
        Jsont.Json.mem (Jsont.Json.name "type")
          (Jsont.Json.string "composer.history_entry");
        Jsont.Json.mem
          (Jsont.Json.name "session_id")
          (Jsont.Json.string (Spice_session.Id.to_string t.session));
        Jsont.Json.mem (Jsont.Json.name "ts") (Jsont.Json.int t.ts);
        Jsont.Json.mem (Jsont.Json.name "draft") (draft_json t.draft);
      ]

  (* Decoding, tolerant throughout: any missing field, wrong type, or malformed
     id yields [None] and the line is skipped. *)

  let span_of_json json =
    match (json_int_mem "start" json, json_int_mem "end" json) with
    | Some first, Some last -> (
        try Some (Draft.Span.make ~first ~last)
        with Invalid_argument _ -> None)
    | Some _, None | None, Some _ | None, None -> None

  let file_ref_of_json json =
    match
      ( json_mem "span" json,
        json_string_mem "path" json,
        json_string_mem "label" json )
    with
    | Some span_json, Some path, Some label -> (
        match span_of_json span_json with
        | Some span -> (
            try Some (span, Draft.File_ref.make ~label path)
            with Invalid_argument _ -> None)
        | None -> None)
    | Some _, Some _, None
    | Some _, None, Some _
    | Some _, None, None
    | None, Some _, Some _
    | None, Some _, None
    | None, None, Some _
    | None, None, None ->
        None

  let pending_paste_of_json json =
    match (json_string_mem "placeholder" json, json_string_mem "text" json) with
    | Some placeholder, Some text ->
        Some { Draft.paste_placeholder = placeholder; paste_text = text }
    | Some _, None | None, Some _ | None, None -> None

  let draft_of_json json =
    match json_string_mem "text" json with
    | None -> None
    | Some text ->
        let file_refs =
          json_list_mem "file_refs" json
          |> Option.value ~default:[]
          |> List.filter_map file_ref_of_json
        in
        let pending_pastes =
          json_list_mem "pending_pastes" json
          |> Option.value ~default:[]
          |> List.filter_map pending_paste_of_json
        in
        Some (Draft.History_entry.make ~file_refs ~pending_pastes text)

  let of_json json =
    match
      ( json_int_mem "schema_version" json,
        json_string_mem "type" json,
        json_string_mem "session_id" json,
        json_int_mem "ts" json,
        json_mem "draft" json )
    with
    | ( Some 1,
        Some "composer.history_entry",
        Some session,
        Some ts,
        Some draft_json ) -> (
        match draft_of_json draft_json with
        | Some draft -> (
            try Some { session = Spice_session.Id.of_string session; ts; draft }
            with Invalid_argument _ -> None)
        | None -> None)
    | Some _, Some _, Some _, Some _, Some _
    | Some _, Some _, Some _, Some _, None
    | Some _, Some _, Some _, None, _
    | Some _, Some _, None, _, _
    | Some _, None, _, _, _
    | None, _, _, _, _ ->
        None
end

let encode entry =
  match Jsont_bytesrw.encode_string Jsont.json (Entry.to_json entry) with
  | Ok line -> line
  | Error message -> invalid_arg ("Spice_tui.History.encode: " ^ message)

let decode line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Error _ -> None
  | Ok json -> (
      match Entry.of_json json with
      | Some entry when not (String.equal (Entry.text entry) "") -> Some entry
      | Some _ | None -> None)

let max_loaded_entries = 200

let rec take n = function
  | [] -> []
  | _ when n <= 0 -> []
  | x :: xs -> x :: take (n - 1) xs

let load contents =
  contents |> String.split_on_char '\n' |> List.filter_map decode |> List.rev
  |> take max_loaded_entries

module Search = struct
  type t = {
    entries : Entry.t list; (* deduped by text, newest first *)
    current : Spice_session.Id.t option;
        (* [None] before the load has attributed a session: nothing ranks as
           current-session, which is also the truth of that moment. *)
    query : string;
    selected : int;
  }

  (* Collapse records with identical text, keeping the first (most recent) so a
     resubmitted prompt appears once (05-overlays-pickers.md §Prompt-history
     search). *)
  let dedup entries =
    let seen = Hashtbl.create 128 in
    List.filter
      (fun entry ->
        let text = Entry.text entry in
        if Hashtbl.mem seen text then false
        else begin
          Hashtbl.add seen text ();
          true
        end)
      entries

  let make ?current ~entries () =
    { entries = dedup entries; current; query = ""; selected = 0 }

  (* Fuzzy match: the query's characters appear in [text] in order, not
     necessarily adjacent (case-insensitive). *)
  let is_subsequence ~needle text =
    let needle = String.lowercase_ascii needle in
    let text = String.lowercase_ascii text in
    let nl = String.length needle and tl = String.length text in
    let rec loop i j =
      if i >= nl then true
      else if j >= tl then false
      else if Char.equal needle.[i] text.[j] then loop (i + 1) (j + 1)
      else loop i (j + 1)
    in
    loop 0 0

  (* Matches ranked current-session-first, each block newest-first (input
     order). *)
  let ranked t =
    let query = String.trim t.query in
    let matching =
      if String.equal query "" then t.entries
      else
        List.filter
          (fun e -> is_subsequence ~needle:query (Entry.text e))
          t.entries
    in
    let this_session, others =
      match t.current with
      | None -> ([], matching)
      | Some current ->
          List.partition
            (fun e -> Spice_session.Id.equal (Entry.session e) current)
            matching
    in
    this_session @ others

  let clamp lo hi x = if x < lo then lo else if x > hi then hi else x

  let with_query query t =
    let count = List.length (ranked { t with query }) in
    let selected =
      if String.equal query t.query then clamp 0 (max 0 (count - 1)) t.selected
      else 0
    in
    { t with query; selected }

  (* A load landing while the search is open swaps in the fresh records and
     attribution; the query stands and the selection clamps. *)
  let refresh ?current ~entries t =
    let t = { t with entries = dedup entries; current } in
    let count = List.length (ranked t) in
    { t with selected = clamp 0 (max 0 (count - 1)) t.selected }

  let selected_entry t =
    Option.map Entry.draft (List.nth_opt (ranked t) t.selected)

  let move dir t =
    let count = List.length (ranked t) in
    if count = 0 then t
    else
      let step = match dir with `Up -> -1 | `Down -> 1 in
      { t with selected = (((t.selected + step) mod count) + count) mod count }

  let first_line text =
    match String.index_opt text '\n' with
    | None -> text
    | Some i -> String.sub text 0 i

  let truncate_tail ~width s =
    if width <= 0 then ""
    else if String.length s <= width then s
    else if width = 1 then "…"
    else
      (* Walk the byte budget back over UTF-8 continuation bytes so the cut
         never splits a scalar in a stored prompt-history row. *)
      let rec cut i =
        if i > 0 && Char.code s.[i] land 0xC0 = 0x80 then cut (i - 1) else i
      in
      String.sub s 0 (cut (width - 1)) ^ "…"

  let title t =
    if String.equal (String.trim t.query) "" then "reverse-i-search:"
    else "reverse-i-search: " ^ t.query

  let row ~width ~selected entry =
    let line =
      truncate_tail ~width:(max 0 (width - 2)) (first_line (Entry.text entry))
    in
    [
      Completion_list.segment
        ?style:(if selected then Some Theme.accent else None)
        line;
    ]

  let view ~width t =
    let header = Mosaic.text ~style:Theme.muted ~wrap:`None (title t) in
    let body =
      match (t.entries, ranked t) with
      | [], _ -> Completion_list.note "no prompt history"
      | _, [] -> Completion_list.note "no matching prompts"
      | _, entries ->
          let rows =
            List.mapi
              (fun i entry -> row ~width ~selected:(i = t.selected) entry)
              entries
          in
          Completion_list.view ~selected:t.selected rows
    in
    Mosaic.box ~flex_direction:Mosaic.Flex_direction.Column
      ~size:{ Mosaic.width = Mosaic.pct 100; height = Mosaic.auto }
      [ header; body ]
end
