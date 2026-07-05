(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Span = struct
  type t = { first : int; last : int }

  let make ~first ~last =
    if first < 0 then invalid_arg "Draft.Span.make: first must be non-negative";
    if last < first then invalid_arg "Draft.Span.make: last must be >= first";
    { first; last }

  let cursor pos = make ~first:pos ~last:pos
  let first t = t.first
  let last t = t.last
  let length t = t.last - t.first
  let is_empty t = t.first = t.last
  let shift offset t = make ~first:(t.first + offset) ~last:(t.last + offset)
  let equal left right = left.first = right.first && left.last = right.last

  let compare left right =
    compare (left.first, left.last) (right.first, right.last)

  let pp ppf t = Format.fprintf ppf "{ first = %d; last = %d }" t.first t.last
end

module File_ref = struct
  type t = { path : string; label : string }

  let make ?label path =
    if String.equal path "" then invalid_arg "Draft.File_ref.make: empty path";
    let label = Option.value label ~default:path in
    if String.equal label "" then invalid_arg "Draft.File_ref.make: empty label";
    { path; label }

  let path t = t.path
  let label t = t.label

  let equal left right =
    String.equal left.path right.path && String.equal left.label right.label

  let pp ppf t = Format.fprintf ppf "{ path = %S; label = %S }" t.path t.label
end

type element = File_ref of File_ref.t | Paste_placeholder of string
type range = { span : Span.t; element : element }
type pending_paste = { paste_placeholder : string; paste_text : string }

module History_entry = struct
  type t = {
    entry_text : string;
    entry_file_refs : (Span.t * File_ref.t) list;
    entry_pending_pastes : pending_paste list;
  }

  let make ?(file_refs = []) ?(pending_pastes = []) text =
    {
      entry_text = text;
      entry_file_refs = file_refs;
      entry_pending_pastes = pending_pastes;
    }

  let of_text text = make text
  let text (t : t) = t.entry_text
  let file_refs (t : t) = t.entry_file_refs
  let pending_pastes (t : t) = t.entry_pending_pastes

  let file_ref_equal (left_span, left_ref) (right_span, right_ref) =
    Span.equal left_span right_span && File_ref.equal left_ref right_ref

  let pending_paste_equal left right =
    String.equal left.paste_placeholder right.paste_placeholder
    && String.equal left.paste_text right.paste_text

  let equal left right =
    String.equal left.entry_text right.entry_text
    && List.equal file_ref_equal left.entry_file_refs right.entry_file_refs
    && List.equal pending_paste_equal left.entry_pending_pastes
         right.entry_pending_pastes
end

type t = {
  visible_text : string;
  cursor : int;
  ranges : range list;
  pending_pastes : pending_paste list;
}

type submitted = {
  submitted_text : string;
  submitted_history_entry : History_entry.t;
}

let large_paste_char_threshold = 800
let large_paste_line_threshold = 3
let empty = { cursor = 0; ranges = []; pending_pastes = []; visible_text = "" }

let of_text text =
  { empty with cursor = String.length text; visible_text = text }

let text (t : t) = t.visible_text
let cursor (t : t) = t.cursor
let ranges (t : t) = t.ranges
let pending_pastes (t : t) = t.pending_pastes

let is_char_boundary text pos =
  pos = 0
  || pos = String.length text
  ||
  let byte = Char.code (String.get text pos) in
  byte land 0xC0 <> 0x80

let check_boundary fn text pos =
  if pos < 0 || pos > String.length text || not (is_char_boundary text pos) then
    invalid_arg (fn ^ ": position is not a valid text boundary")

let check_span fn text span =
  check_boundary fn text (Span.first span);
  check_boundary fn text (Span.last span);
  if Span.last span > String.length text then
    invalid_arg (fn ^ ": range exceeds draft text")

let with_cursor cursor (t : t) =
  check_boundary "Draft.with_cursor" (text t) cursor;
  { t with cursor }

let element_overlaps_span span range =
  let first = Span.first span in
  let last = Span.last span in
  let range_first = Span.first range.span in
  let range_last = Span.last range.span in
  if Span.is_empty span then first > range_first && first < range_last
  else range_first < last && first < range_last

let replacement_span span ranges =
  List.fold_left
    (fun acc range ->
      if element_overlaps_span acc range then
        Span.make
          ~first:(min (Span.first acc) (Span.first range.span))
          ~last:(max (Span.last acc) (Span.last range.span))
      else acc)
    span ranges

let shifted_range span replacement_len range =
  let first = Span.first range.span in
  let last = Span.last range.span in
  if last <= Span.first span then Some range
  else if first >= Span.last span then
    let delta = replacement_len - Span.length span in
    Some { range with span = Span.shift delta range.span }
  else None

let pending_pastes_for_ranges pending ranges =
  List.filter
    (fun paste ->
      List.exists
        (function
          | { element = Paste_placeholder placeholder; _ } ->
              String.equal placeholder paste.paste_placeholder
          | { element = File_ref _; _ } -> false)
        ranges)
    pending

let range_overlaps_span left right =
  Span.first left < Span.last right && Span.first right < Span.last left

let range_visible_text_matches text span visible =
  let first = Span.first span in
  let last = Span.last span in
  first >= 0
  && last <= String.length text
  && is_char_boundary text first
  && is_char_boundary text last
  && String.equal (String.sub text first (last - first)) visible

let history_file_ref_range text (span, file_ref) =
  if range_visible_text_matches text span (File_ref.label file_ref) then
    Some { span; element = File_ref file_ref }
  else None

let substring_at text pos needle =
  let needle_len = String.length needle in
  pos + needle_len <= String.length text
  &&
  let rec loop index =
    index = needle_len
    || Char.equal (String.get text (pos + index)) (String.get needle index)
       && loop (index + 1)
  in
  loop 0

let find_unblocked_substring_span text ~start ~blocked needle =
  let needle_len = String.length needle in
  if needle_len = 0 then None
  else
    let rec loop pos =
      if pos + needle_len > String.length text then None
      else if substring_at text pos needle then
        let span = Span.make ~first:pos ~last:(pos + needle_len) in
        if
          List.exists (fun range -> range_overlaps_span span range.span) blocked
        then loop (pos + 1)
        else Some span
      else loop (pos + 1)
    in
    loop start

let history_paste_ranges text ~blocked pending_pastes =
  let rec loop search_from blocked ranges pending = function
    | [] -> (List.rev ranges, List.rev pending)
    | paste :: rest -> (
        match
          find_unblocked_substring_span text ~start:search_from ~blocked
            paste.paste_placeholder
        with
        | None -> loop search_from blocked ranges pending rest
        | Some span ->
            let range =
              { span; element = Paste_placeholder paste.paste_placeholder }
            in
            loop (Span.last span) (range :: blocked) (range :: ranges)
              (paste :: pending) rest)
  in
  loop 0 blocked [] [] pending_pastes

let replace_range span replacement (t : t) =
  let draft_text = text t in
  let draft_ranges = ranges t in
  check_span "Draft.replace_range" draft_text span;
  let span = replacement_span span draft_ranges in
  let before = String.sub draft_text 0 (Span.first span) in
  let after =
    String.sub draft_text (Span.last span)
      (String.length draft_text - Span.last span)
  in
  let ranges =
    List.filter_map
      (shifted_range span (String.length replacement))
      draft_ranges
  in
  {
    visible_text = before ^ replacement ^ after;
    cursor = Span.first span + String.length replacement;
    ranges;
    pending_pastes = pending_pastes_for_ranges (pending_pastes t) ranges;
  }

let common_prefix_len left right =
  let left_len = String.length left in
  let right_len = String.length right in
  let max_len = min left_len right_len in
  let rec loop index =
    if index = max_len then index
    else if Char.equal (String.get left index) (String.get right index) then
      loop (index + 1)
    else index
  in
  let raw_len = loop 0 in
  let rec boundary_len index =
    if is_char_boundary left index && is_char_boundary right index then index
    else boundary_len (index - 1)
  in
  boundary_len raw_len

let common_suffix_len ~prefix left right =
  let left_len = String.length left in
  let right_len = String.length right in
  let max_len = min (left_len - prefix) (right_len - prefix) in
  let rec loop offset =
    if offset = max_len then offset
    else
      let next_offset = offset + 1 in
      if
        Char.equal
          (String.get left (left_len - next_offset))
          (String.get right (right_len - next_offset))
      then loop next_offset
      else offset
  in
  let raw_len = loop 0 in
  let rec boundary_len len =
    if
      is_char_boundary left (left_len - len)
      && is_char_boundary right (right_len - len)
    then len
    else boundary_len (len - 1)
  in
  boundary_len raw_len

let replace_visible_text new_text (t : t) =
  let old_text = text t in
  if String.equal old_text new_text then t
  else
    let prefix = common_prefix_len old_text new_text in
    let suffix = common_suffix_len ~prefix old_text new_text in
    let old_last = String.length old_text - suffix in
    let new_last = String.length new_text - suffix in
    let span = Span.make ~first:prefix ~last:old_last in
    let replacement = String.sub new_text prefix (new_last - prefix) in
    replace_range span replacement t

let insert_text inserted t = replace_range (Span.cursor t.cursor) inserted t

let insert_element visible element t =
  let start = t.cursor in
  let t = insert_text visible t in
  let span = Span.make ~first:start ~last:t.cursor in
  { t with ranges = { span; element } :: t.ranges |> List.sort compare }

let insert_file_ref ?label ~path t =
  let file_ref = File_ref.make ?label path in
  insert_element (File_ref.label file_ref) (File_ref file_ref) t

let file_ref_token_char = '@'

let is_token_boundary = function
  | ' ' | '\n' | '\r' | '\t' | '\011' | '\012' -> true
  | _ -> false

let active_file_ref_token_span t =
  let draft_text = text t in
  check_boundary "Draft.active_file_ref_token_span" draft_text t.cursor;
  let len = String.length draft_text in
  let rec token_start index =
    if index = 0 then 0
    else
      let previous = index - 1 in
      if is_token_boundary (String.get draft_text previous) then index
      else token_start previous
  in
  let rec token_end index =
    if index >= len then len
    else if is_token_boundary (String.get draft_text index) then index
    else token_end (index + 1)
  in
  let first = token_start t.cursor in
  let last = token_end t.cursor in
  if
    first < last && Char.equal (String.get draft_text first) file_ref_token_char
  then Some (Span.make ~first ~last)
  else None

let replace_active_file_ref_token ?label ~path t =
  let span =
    active_file_ref_token_span t |> Option.value ~default:(Span.cursor t.cursor)
  in
  t |> replace_range span "" |> insert_file_ref ?label ~path

let normalize_paste text =
  let buffer = Buffer.create (String.length text) in
  let rec loop index =
    if index < String.length text then
      match String.get text index with
      | '\r'
        when index + 1 < String.length text
             && Char.equal (String.get text (index + 1)) '\n' ->
          Buffer.add_char buffer '\n';
          loop (index + 2)
      | '\r' ->
          Buffer.add_char buffer '\n';
          loop (index + 1)
      | char ->
          Buffer.add_char buffer char;
          loop (index + 1)
  in
  loop 0;
  Buffer.contents buffer

let scalar_count text =
  let rec loop index count =
    if index >= String.length text then count
    else
      let decode = String.get_utf_8_uchar text index in
      loop (index + Uchar.utf_decode_length decode) (count + 1)
  in
  loop 0 0

let newline_count text =
  String.fold_left
    (fun count char -> if Char.equal char '\n' then count + 1 else count)
    0 text

let digits_end text start =
  let rec loop index =
    if index < String.length text && Char.Ascii.is_digit (String.get text index)
    then loop (index + 1)
    else index
  in
  loop start

(* An attachment placeholder token starting at [index]: [[Pasted text #N]],
   [[Pasted text #N +M lines]], or [[Image #N]]. *)
let placeholder_id_at text index =
  let id_after start =
    let stop = digits_end text start in
    if stop = start then None
    else
      let suffix_ok =
        substring_at text stop "]"
        || substring_at text stop " +"
           &&
           let lines_stop = digits_end text (stop + 2) in
           lines_stop > stop + 2 && substring_at text lines_stop " lines]"
      in
      if suffix_ok then int_of_string_opt (String.sub text start (stop - start))
      else None
  in
  if substring_at text index "[Pasted text #" then
    id_after (index + String.length "[Pasted text #")
  else if substring_at text index "[Image #" then
    id_after (index + String.length "[Image #")
  else None

let max_placeholder_id text =
  let rec loop index max_id =
    if index >= String.length text then max_id
    else
      match placeholder_id_at text index with
      | Some id -> loop (index + 1) (max max_id id)
      | None -> loop (index + 1) max_id
  in
  loop 0 0

(* Placeholder IDs share one namespace across paste and image tokens and are
   allocated past every ID visible in the text or held by a pending payload, so
   hand-typed lookalikes and history-restored chunks never collide with a fresh
   paste. IDs of fully deleted chunks may be reused; their payloads are
   unreachable. *)
let next_paste_id t =
  let from_pending =
    List.fold_left
      (fun max_id paste ->
        max max_id (max_placeholder_id paste.paste_placeholder))
      0 t.pending_pastes
  in
  1 + max (max_placeholder_id (text t)) from_pending

let paste_placeholder_label ~id ~newlines =
  if newlines = 0 then Printf.sprintf "[Pasted text #%d]" id
  else Printf.sprintf "[Pasted text #%d +%d lines]" id newlines

let insert_paste ?(char_threshold = large_paste_char_threshold)
    ?(line_threshold = large_paste_line_threshold) pasted t =
  let pasted = normalize_paste pasted in
  let newlines = newline_count pasted in
  (* One trailing newline is not a line of content: a shell copy of two lines
     ends with "\n" and must not count as three. *)
  let content_lines =
    let counted =
      if newlines > 0 && String.ends_with ~suffix:"\n" pasted then newlines - 1
      else newlines
    in
    counted + 1
  in
  if content_lines >= line_threshold || scalar_count pasted > char_threshold
  then
    let placeholder = paste_placeholder_label ~id:(next_paste_id t) ~newlines in
    let t = insert_element placeholder (Paste_placeholder placeholder) t in
    {
      t with
      pending_pastes =
        t.pending_pastes
        @ [ { paste_placeholder = placeholder; paste_text = pasted } ];
    }
  else insert_text pasted t

let pop_pending_placeholder placeholder pending =
  let rec loop kept = function
    | [] -> (None, List.rev kept)
    | paste :: rest when String.equal paste.paste_placeholder placeholder ->
        (Some paste.paste_text, List.rev_append kept rest)
    | paste :: rest -> loop (paste :: kept) rest
  in
  loop [] pending

let expand_paste_placeholders (t : t) =
  if t.pending_pastes = [] || t.ranges = [] then t
  else
    let ranges =
      List.sort (fun left right -> Span.compare left.span right.span) t.ranges
    in
    let draft_text = text t in
    let rebuilt = Buffer.create (String.length draft_text) in
    let rebuilt_ranges = ref [] in
    let cursor = ref 0 in
    let pending = ref t.pending_pastes in
    List.iter
      (fun range ->
        let first = min (Span.first range.span) (String.length draft_text) in
        let last = min (Span.last range.span) (String.length draft_text) in
        if first >= !cursor && last >= first then (
          Buffer.add_substring rebuilt draft_text !cursor (first - !cursor);
          let visible = String.sub draft_text first (last - first) in
          (match range.element with
          | Paste_placeholder placeholder -> (
              let replacement, remaining =
                pop_pending_placeholder placeholder !pending
              in
              pending := remaining;
              match replacement with
              | Some text -> Buffer.add_string rebuilt text
              | None ->
                  let new_first = Buffer.length rebuilt in
                  Buffer.add_string rebuilt visible;
                  let new_last = Buffer.length rebuilt in
                  rebuilt_ranges :=
                    {
                      span = Span.make ~first:new_first ~last:new_last;
                      element = range.element;
                    }
                    :: !rebuilt_ranges)
          | File_ref _ ->
              let new_first = Buffer.length rebuilt in
              Buffer.add_string rebuilt visible;
              let new_last = Buffer.length rebuilt in
              rebuilt_ranges :=
                {
                  span = Span.make ~first:new_first ~last:new_last;
                  element = range.element;
                }
                :: !rebuilt_ranges);
          cursor := last))
      ranges;
    if !cursor < String.length draft_text then
      Buffer.add_substring rebuilt draft_text !cursor
        (String.length draft_text - !cursor);
    let text = Buffer.contents rebuilt in
    {
      visible_text = text;
      cursor = String.length text;
      ranges = List.rev !rebuilt_ranges;
      pending_pastes = !pending;
    }

let is_blank t =
  String.equal (String.trim (text (expand_paste_placeholders t))) ""

type run_kind = Plain | Atom

let runs (t : t) =
  let draft_text = text t in
  let ordered =
    List.sort (fun left right -> Span.compare left.span right.span) (ranges t)
  in
  let plain first last acc =
    if last > first then (Span.make ~first ~last, Plain) :: acc else acc
  in
  let rec loop cursor acc = function
    | [] -> List.rev (plain cursor (String.length draft_text) acc)
    | { span; _ } :: rest ->
        let first = Span.first span in
        let last = Span.last span in
        let acc = plain cursor first acc in
        loop last ((span, Atom) :: acc) rest
  in
  loop 0 [] ordered

let trim_left_len text =
  let is_space = function
    | ' ' | '\n' | '\r' | '\t' | '\011' | '\012' -> true
    | _ -> false
  in
  let rec loop index =
    if index = String.length text then index
    else if is_space (String.get text index) then loop (index + 1)
    else index
  in
  loop 0

let trim_ranges original trimmed ranges =
  if String.equal trimmed "" then []
  else
    let trim_start = trim_left_len original in
    let trim_last = trim_start + String.length trimmed in
    List.filter_map
      (fun range ->
        let first = Span.first range.span in
        let last = Span.last range.span in
        if last <= trim_start || first >= trim_last then None
        else
          let first = max first trim_start - trim_start in
          let last = min last trim_last - trim_start in
          if first >= last then None
          else Some { range with span = Span.make ~first ~last })
      ranges

let history_entry (t : t) =
  let file_refs =
    t.ranges
    |> List.filter_map (function
      | { span; element = File_ref file_ref } -> Some (span, file_ref)
      | { element = Paste_placeholder _; _ } -> None)
  in
  History_entry.make ~file_refs ~pending_pastes:t.pending_pastes (text t)

let of_history_entry entry =
  let entry_text = History_entry.text entry in
  let file_ref_ranges =
    History_entry.file_refs entry
    |> List.filter_map (history_file_ref_range entry_text)
  in
  let paste_ranges, pending_pastes =
    history_paste_ranges entry_text ~blocked:file_ref_ranges
      (History_entry.pending_pastes entry)
  in
  let ranges =
    List.sort
      (fun left right -> Span.compare left.span right.span)
      (file_ref_ranges @ paste_ranges)
  in
  {
    visible_text = entry_text;
    cursor = String.length entry_text;
    ranges;
    pending_pastes;
  }

let submit (t : t) =
  let expanded = expand_paste_placeholders t in
  let expanded_text = text expanded in
  let submitted_text = String.trim expanded_text in
  if String.equal submitted_text "" then None
  else
    let ranges = trim_ranges expanded_text submitted_text expanded.ranges in
    let submitted_draft =
      {
        visible_text = submitted_text;
        cursor = String.length submitted_text;
        ranges;
        pending_pastes = [];
      }
    in
    let history_entry = history_entry submitted_draft in
    Some ({ submitted_text; submitted_history_entry = history_entry }, empty)
