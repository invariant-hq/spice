(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Label = struct
  type t = string

  let invalid_char = function '\n' | '\r' | '\000' -> true | _ -> false
  let has_invalid_char = String.exists invalid_char

  let of_string label =
    if String.is_empty label then invalid_arg "diff label must not be empty";
    if has_invalid_char label then invalid_arg "diff label is malformed";
    label

  let escaped label =
    let label =
      if String.is_empty label then "<empty>" else String.escaped label
    in
    of_string label

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t
end

module File_change = struct
  type t =
    | Add of { label : Label.t; contents : string }
    | Delete of { label : Label.t; contents : string }
    | Modify of { label : Label.t; before : string; after : string }

  let of_states ~label ~before ~after =
    match (before, after) with
    | None, None -> None
    | None, Some contents -> Some (Add { label; contents })
    | Some contents, None -> Some (Delete { label; contents })
    | Some before, Some after -> Some (Modify { label; before; after })

  let create ~label ~contents = Add { label; contents }
  let delete ~label ~contents = Delete { label; contents }
  let modify ~label ~before ~after = Modify { label; before; after }

  let label = function
    | Add file -> file.label
    | Delete file -> file.label
    | Modify file -> file.label

  let before = function
    | Add _ -> None
    | Delete file -> Some file.contents
    | Modify file -> Some file.before

  let after = function
    | Add file -> Some file.contents
    | Delete _ -> None
    | Modify file -> Some file.after
end

type stats = { files : int; additions : int; deletions : int }

module Limits = struct
  type t = {
    max_files : int;
    max_file_bytes : int;
    max_lines : int;
    max_edit_distance : int option;
  }

  let make ~max_files ~max_file_bytes ~max_lines ?max_edit_distance () =
    if max_files < 0 then invalid_arg "max_files must be non-negative";
    if max_file_bytes < 0 then invalid_arg "max_file_bytes must be non-negative";
    if max_lines < 0 then invalid_arg "max_lines must be non-negative";
    Option.iter
      (fun max_edit_distance ->
        if max_edit_distance < 0 then
          invalid_arg "max_edit_distance must be non-negative")
      max_edit_distance;
    { max_files; max_file_bytes; max_lines; max_edit_distance }
end

type render_mode = [ `Display | `Raw ]
type t = { text : string; stats : stats; omitted : int }
type line = { content : string; newline : bool }
type op = Delete_line of line | Insert_line of line | Keep_line of line

type indexed_op = {
  op : op;
  indexed_before_start : int;
  indexed_before_len : int;
  indexed_after_start : int;
  indexed_after_len : int;
}

type file_text = {
  before_state : string option;
  after_state : string option;
  before_text : string;
  after_text : string;
}

type hunk = {
  before_start : int;
  before_len : int;
  after_start : int;
  after_len : int;
  lines : (char * line) list;
}

let empty_stats = { files = 0; additions = 0; deletions = 0 }

let stats_v ~files ~additions ~deletions =
  if files < 0 || additions < 0 || deletions < 0 then
    invalid_arg "Spice_diff.stats_v: counts must be non-negative";
  { files; additions; deletions }

let validate_context context =
  if context < 0 then invalid_arg "context must be non-negative";
  context

let file_text file =
  let before_state = File_change.before file in
  let after_state = File_change.after file in
  {
    before_state;
    after_state;
    before_text = Option.value before_state ~default:"";
    after_text = Option.value after_state ~default:"";
  }

let is_noop = function
  | File_change.Modify { before; after; _ } -> String.equal before after
  | File_change.Add _ | File_change.Delete _ -> false

let split_lines text =
  let len = String.length text in
  let rec count acc i =
    if i = len then
      if len > 0 && not (Char.equal text.[len - 1] '\n') then acc + 1 else acc
    else if Char.equal text.[i] '\n' then count (acc + 1) (i + 1)
    else count acc (i + 1)
  in
  let count = count 0 0 in
  if count = 0 then [||]
  else
    (* The first pass counted the exact number of output lines, so the unsafe
       writes below stay within [lines]. *)
    let lines = Array.make count { content = ""; newline = true } in
    let rec fill line start i =
      if i = len then
        if start < len then
          Array.unsafe_set lines line
            { content = String.sub text start (len - start); newline = false }
        else ()
      else if Char.equal text.[i] '\n' then begin
        Array.unsafe_set lines line
          { content = String.sub text start (i - start); newline = true };
        fill (line + 1) (i + 1) (i + 1)
      end
      else fill line start (i + 1)
    in
    fill 0 0 0;
    lines

let line_equal a b =
  String.equal a.content b.content && Bool.equal a.newline b.newline

let edit_script ?max_distance before after =
  let exception Found of int in
  let n = Array.length before in
  let m = Array.length after in
  let max_d = n + m in
  if max_d = 0 then Some []
  else
    let search_limit = min max_d (Option.value max_distance ~default:max_d) in
    let offset = search_limit in
    let v = Array.make ((2 * search_limit) + 3) (-1) in
    let traces = Array.make (search_limit + 1) [||] in
    v.(offset + 1) <- 0;
    try
      for d = 0 to search_limit do
        for k = -d to d do
          if (k + d) mod 2 = 0 then begin
            let x =
              if k = -d || (k <> d && v.(offset + k - 1) < v.(offset + k + 1))
              then v.(offset + k + 1)
              else v.(offset + k - 1) + 1
            in
            let x = ref x in
            let y = ref (!x - k) in
            while !x < n && !y < m && line_equal before.(!x) after.(!y) do
              incr x;
              incr y
            done;
            v.(offset + k) <- !x;
            if !x >= n && !y >= m then begin
              traces.(d) <- Array.copy v;
              raise_notrace (Found d)
            end
          end
        done;
        traces.(d) <- Array.copy v
      done;
      if search_limit < max_d then None else Some []
    with Found d_final ->
      let x = ref n in
      let y = ref m in
      let ops = ref [] in
      for d = d_final downto 1 do
        let k = !x - !y in
        let previous = traces.(d - 1) in
        let previous_k =
          if
            k = -d
            || (k <> d && previous.(offset + k - 1) < previous.(offset + k + 1))
          then k + 1
          else k - 1
        in
        let previous_x = previous.(offset + previous_k) in
        let previous_y = previous_x - previous_k in
        while !x > previous_x && !y > previous_y do
          ops := Keep_line before.(!x - 1) :: !ops;
          decr x;
          decr y
        done;
        if previous_k = k + 1 then ops := Insert_line after.(previous_y) :: !ops
        else ops := Delete_line before.(previous_x) :: !ops;
        x := previous_x;
        y := previous_y
      done;
      while !x > 0 && !y > 0 do
        ops := Keep_line before.(!x - 1) :: !ops;
        decr x;
        decr y
      done;
      while !x > 0 do
        ops := Delete_line before.(!x - 1) :: !ops;
        decr x
      done;
      while !y > 0 do
        ops := Insert_line after.(!y - 1) :: !ops;
        decr y
      done;
      Some !ops

let edit_stats before after =
  let exception Found of int in
  let n = Array.length before in
  let m = Array.length after in
  let max_d = n + m in
  if max_d = 0 then { files = 1; additions = 0; deletions = 0 }
  else
    let offset = max_d in
    let v = Array.make ((2 * max_d) + 3) (-1) in
    v.(offset + 1) <- 0;
    let distance =
      try
        for d = 0 to max_d do
          for k = -d to d do
            if (k + d) mod 2 = 0 then begin
              let x =
                if k = -d || (k <> d && v.(offset + k - 1) < v.(offset + k + 1))
                then v.(offset + k + 1)
                else v.(offset + k - 1) + 1
              in
              let x = ref x in
              let y = ref (!x - k) in
              while !x < n && !y < m && line_equal before.(!x) after.(!y) do
                incr x;
                incr y
              done;
              v.(offset + k) <- !x;
              if !x >= n && !y >= m then raise_notrace (Found d)
            end
          done
        done;
        max_d
      with Found d -> d
    in
    {
      files = 1;
      additions = (distance + m - n) / 2;
      deletions = (distance + n - m) / 2;
    }

let indexed_ops ops =
  let before_line = ref 1 in
  let after_line = ref 1 in
  let entry op before_len after_len =
    let entry : indexed_op =
      {
        op;
        indexed_before_start = !before_line;
        indexed_before_len = before_len;
        indexed_after_start = !after_line;
        indexed_after_len = after_len;
      }
    in
    before_line := !before_line + before_len;
    after_line := !after_line + after_len;
    entry
  in
  Array.of_list
    (List.map
       (function
         | Keep_line _ as op -> entry op 1 1
         | Delete_line _ as op -> entry op 1 0
         | Insert_line _ as op -> entry op 0 1)
       ops)

let is_change entry =
  match entry.op with
  | Keep_line _ -> false
  | Delete_line _ | Insert_line _ -> true

let changed_blocks entries =
  let len = Array.length entries in
  let rec loop blocks i =
    if i >= len then List.rev blocks
    else if not (is_change entries.(i)) then loop blocks (i + 1)
    else
      let start = i in
      let rec finish i =
        if i >= len || not (is_change entries.(i)) then i - 1 else finish (i + 1)
      in
      let last = finish i in
      loop ((start, last) :: blocks) (last + 1)
  in
  loop [] 0

let expand_block entries ~context (start, last) =
  let len = Array.length entries in
  let first = if context >= start then 0 else start - context in
  let after_last = len - 1 - last in
  let last = if context >= after_last then len - 1 else last + context in
  (first, last)

let merge_ranges ranges =
  let rec loop merged = function
    | [] -> List.rev merged
    | (start, last) :: ranges -> (
        match merged with
        | (merged_start, merged_last) :: rest when start <= merged_last + 1 ->
            loop ((merged_start, max merged_last last) :: rest) ranges
        | _ -> loop ((start, last) :: merged) ranges)
  in
  loop [] ranges

let line_of_op = function
  | Keep_line line | Delete_line line | Insert_line line -> line

let prefix_of_op = function
  | Keep_line _ -> ' '
  | Delete_line _ -> '-'
  | Insert_line _ -> '+'

let hunk_of_range (entries : indexed_op array) (start, last) =
  let before_start = ref None in
  let after_start = ref None in
  let before_len = ref 0 in
  let after_len = ref 0 in
  let lines = ref [] in
  for i = start to last do
    let entry : indexed_op = entries.(i) in
    if entry.indexed_before_len > 0 then begin
      if Option.is_none !before_start then
        before_start := Some entry.indexed_before_start;
      before_len := !before_len + entry.indexed_before_len
    end;
    if entry.indexed_after_len > 0 then begin
      if Option.is_none !after_start then
        after_start := Some entry.indexed_after_start;
      after_len := !after_len + entry.indexed_after_len
    end;
    lines := (prefix_of_op entry.op, line_of_op entry.op) :: !lines
  done;
  ({
     before_start =
       Option.value !before_start ~default:entries.(start).indexed_before_start;
     before_len = !before_len;
     after_start =
       Option.value !after_start ~default:entries.(start).indexed_after_start;
     after_len = !after_len;
     lines = List.rev !lines;
   }
    : hunk)

let hunks_of_ops ~context ops =
  let entries = indexed_ops ops in
  changed_blocks entries
  |> List.map (expand_block entries ~context)
  |> merge_ranges
  |> List.map (hunk_of_range entries)

module Hunk = struct
  module Line = struct
    type kind = Context | Added | Removed

    type t = {
      kind : kind;
      text : string;
      newline : bool;
      old_line : int option;
      new_line : int option;
    }

    let kind (line : t) = line.kind
    let text (line : t) = line.text
    let newline (line : t) = line.newline
    let old_line (line : t) = line.old_line
    let new_line (line : t) = line.new_line
    let kind_rank = function Context -> 0 | Removed -> 1 | Added -> 2

    let equal a b =
      Int.equal (kind_rank a.kind) (kind_rank b.kind)
      && String.equal a.text b.text
      && Bool.equal a.newline b.newline
      && Option.equal Int.equal a.old_line b.old_line
      && Option.equal Int.equal a.new_line b.new_line

    let prefix_char = function Context -> ' ' | Removed -> '-' | Added -> '+'

    let pp ppf line =
      Format.fprintf ppf "%c%s" (prefix_char line.kind) line.text
  end

  type t = {
    old_start : int;
    old_count : int;
    new_start : int;
    new_count : int;
    lines : Line.t list;
  }

  let old_start (hunk : t) = hunk.old_start
  let old_count (hunk : t) = hunk.old_count
  let new_start (hunk : t) = hunk.new_start
  let new_count (hunk : t) = hunk.new_count
  let lines (hunk : t) = hunk.lines

  let equal a b =
    Int.equal a.old_start b.old_start
    && Int.equal a.old_count b.old_count
    && Int.equal a.new_start b.new_start
    && Int.equal a.new_count b.new_count
    && List.equal Line.equal a.lines b.lines

  let pp ppf hunk =
    let header start count = if count = 0 then start - 1 else start in
    Format.fprintf ppf "@@@@ -%d,%d +%d,%d @@@@"
      (header hunk.old_start hunk.old_count)
      hunk.old_count
      (header hunk.new_start hunk.new_count)
      hunk.new_count;
    List.iter (fun line -> Format.fprintf ppf "@\n%a" Line.pp line) hunk.lines
end

let hunk_lines (hunk : hunk) =
  (* Removals before additions within each change block, matching rendered
     unified output. Relative order within each side is preserved, so the
     sequential counters below assign the correct absolute line numbers. *)
  let regrouped =
    let out = ref [] in
    let deletions = ref [] in
    let insertions = ref [] in
    let flush () =
      List.iter (fun line -> out := ('-', line) :: !out) (List.rev !deletions);
      List.iter (fun line -> out := ('+', line) :: !out) (List.rev !insertions);
      deletions := [];
      insertions := []
    in
    List.iter
      (fun (prefix, line) ->
        match prefix with
        | '-' -> deletions := line :: !deletions
        | '+' -> insertions := line :: !insertions
        | _ ->
            flush ();
            out := (' ', line) :: !out)
      hunk.lines;
    flush ();
    List.rev !out
  in
  let old_line = ref hunk.before_start in
  let new_line = ref hunk.after_start in
  List.map
    (fun (prefix, line) ->
      match prefix with
      | ' ' ->
          let old_no = !old_line and new_no = !new_line in
          incr old_line;
          incr new_line;
          {
            Hunk.Line.kind = Hunk.Line.Context;
            text = line.content;
            newline = line.newline;
            old_line = Some old_no;
            new_line = Some new_no;
          }
      | '-' ->
          let old_no = !old_line in
          incr old_line;
          {
            Hunk.Line.kind = Hunk.Line.Removed;
            text = line.content;
            newline = line.newline;
            old_line = Some old_no;
            new_line = None;
          }
      | _ ->
          let new_no = !new_line in
          incr new_line;
          {
            Hunk.Line.kind = Hunk.Line.Added;
            text = line.content;
            newline = line.newline;
            old_line = None;
            new_line = Some new_no;
          })
    regrouped

let hunks ?(context = 3) ?max_edit_distance ~before ~after () =
  let context = validate_context context in
  Option.iter
    (fun max_edit_distance ->
      if max_edit_distance < 0 then
        invalid_arg "max_edit_distance must be non-negative")
    max_edit_distance;
  match
    edit_script ?max_distance:max_edit_distance (split_lines before)
      (split_lines after)
  with
  | None -> None
  | Some ops ->
      Some
        (List.map
           (fun (hunk : hunk) ->
             {
               Hunk.old_start = hunk.before_start;
               old_count = hunk.before_len;
               new_start = hunk.after_start;
               new_count = hunk.after_len;
               lines = hunk_lines hunk;
             })
           (hunks_of_ops ~context ops))

let starts_with_at text ~prefix ~at =
  let len = String.length text in
  let prefix_len = String.length prefix in
  at + prefix_len <= len
  &&
  let rec loop i =
    i = prefix_len || (Char.equal text.[at + i] prefix.[i] && loop (i + 1))
  in
  loop 0

let bidi_escapes =
  [|
    ("\216\156", "\\u{061c}");
    ("\226\128\142", "\\u{200e}");
    ("\226\128\143", "\\u{200f}");
    ("\226\128\170", "\\u{202a}");
    ("\226\128\171", "\\u{202b}");
    ("\226\128\172", "\\u{202c}");
    ("\226\128\173", "\\u{202d}");
    ("\226\128\174", "\\u{202e}");
    ("\226\129\166", "\\u{2066}");
    ("\226\129\167", "\\u{2067}");
    ("\226\129\168", "\\u{2068}");
    ("\226\129\169", "\\u{2069}");
  |]

let bidi_escape text i =
  let rec loop j =
    if j = Array.length bidi_escapes then None
    else
      let prefix, escape = bidi_escapes.(j) in
      if starts_with_at text ~prefix ~at:i then
        Some (escape, String.length prefix)
      else loop (j + 1)
  in
  loop 0

let add_escaped_byte buffer byte =
  Buffer.add_string buffer "\\x";
  let hex = "0123456789ABCDEF" in
  Buffer.add_char buffer hex.[byte lsr 4];
  Buffer.add_char buffer hex.[byte land 0xF]

let add_display_string buffer text =
  let len = String.length text in
  let rec loop i =
    if i < len then
      match bidi_escape text i with
      | Some (escape, width) ->
          Buffer.add_string buffer escape;
          loop (i + width)
      | None ->
          let char = text.[i] in
          let code = Char.code char in
          if (code < 0x20 && not (Char.equal char '\t')) || code = 0x7F then
            add_escaped_byte buffer code
          else Buffer.add_char buffer char;
          loop (i + 1)
  in
  loop 0

let add_mode_string buffer mode text =
  match mode with
  | `Raw -> Buffer.add_string buffer text
  | `Display -> add_display_string buffer text

let hunk_start start len = if len = 0 then start - 1 else start
let add_int buffer n = Buffer.add_string buffer (string_of_int n)

let add_line buffer mode prefix line =
  Buffer.add_char buffer prefix;
  add_mode_string buffer mode line.content;
  Buffer.add_char buffer '\n';
  if not line.newline then
    Buffer.add_string buffer "\\ No newline at end of file\n"

let render_hunk buffer mode (hunk : hunk) =
  Buffer.add_string buffer "@@ -";
  add_int buffer (hunk_start hunk.before_start hunk.before_len);
  Buffer.add_char buffer ',';
  add_int buffer hunk.before_len;
  Buffer.add_string buffer " +";
  add_int buffer (hunk_start hunk.after_start hunk.after_len);
  Buffer.add_char buffer ',';
  add_int buffer hunk.after_len;
  Buffer.add_string buffer " @@\n";
  let deletions = ref [] in
  let insertions = ref [] in
  let flush_changes () =
    List.iter (fun line -> add_line buffer mode '-' line) (List.rev !deletions);
    List.iter (fun line -> add_line buffer mode '+' line) (List.rev !insertions);
    deletions := [];
    insertions := []
  in
  List.iter
    (fun (prefix, line) ->
      match prefix with
      | '-' -> deletions := line :: !deletions
      | '+' -> insertions := line :: !insertions
      | _ ->
          flush_changes ();
          add_line buffer mode ' ' line)
    hunk.lines;
  flush_changes ()

let add_file_header buffer mode ~before_label ~after_label =
  Buffer.add_string buffer "--- ";
  add_mode_string buffer mode before_label;
  Buffer.add_char buffer '\n';
  Buffer.add_string buffer "+++ ";
  add_mode_string buffer mode after_label;
  Buffer.add_char buffer '\n'

let stats_for_ops ops =
  let additions = ref 0 in
  let deletions = ref 0 in
  List.iter
    (function
      | Insert_line _ -> incr additions
      | Delete_line _ -> incr deletions
      | Keep_line _ -> ())
    ops;
  { files = 1; additions = !additions; deletions = !deletions }

let ops_for_file_text ?max_distance text =
  edit_script ?max_distance
    (split_lines text.before_text)
    (split_lines text.after_text)

let diff_label label = function None -> "/dev/null" | Some _ -> label

let stats_for_file file =
  if is_noop file then empty_stats
  else
    let text = file_text file in
    edit_stats (split_lines text.before_text) (split_lines text.after_text)

let add_omission buffer reason =
  Buffer.add_string buffer "[diff omitted: ";
  Buffer.add_string buffer reason;
  Buffer.add_string buffer "]\n"

let line_count text =
  let len = String.length text in
  let rec loop count i =
    if i = len then
      if len > 0 && not (Char.equal text.[len - 1] '\n') then count + 1
      else count
    else if Char.equal text.[i] '\n' then loop (count + 1) (i + 1)
    else loop count (i + 1)
  in
  loop 0 0

let max_text_bytes text =
  max (String.length text.before_text) (String.length text.after_text)

let max_text_lines text =
  max (line_count text.before_text) (line_count text.after_text)

let render_omitted_file ~omitted buffer mode file text reason =
  let label = Label.to_string (File_change.label file) in
  let before_label = diff_label label text.before_state in
  let after_label = diff_label label text.after_state in
  add_file_header buffer mode ~before_label ~after_label;
  add_omission buffer reason;
  incr omitted;
  { files = 1; additions = 0; deletions = 0 }

let render_file_text_into ?limits ~context ~omitted buffer mode file text =
  let label = Label.to_string (File_change.label file) in
  match limits with
  | Some limits when max_text_bytes text > limits.Limits.max_file_bytes ->
      render_omitted_file ~omitted buffer mode file text
        (Printf.sprintf "file exceeds %d byte display limit"
           limits.Limits.max_file_bytes)
  | Some limits when max_text_lines text > limits.Limits.max_lines ->
      render_omitted_file ~omitted buffer mode file text
        (Printf.sprintf "file exceeds %d line display limit"
           limits.Limits.max_lines)
  | _ -> (
      let max_distance =
        Option.bind limits (fun limits -> limits.Limits.max_edit_distance)
      in
      match ops_for_file_text ?max_distance text with
      | None -> (
          match max_distance with
          | Some max_distance ->
              render_omitted_file ~omitted buffer mode file text
                (Printf.sprintf "edit distance exceeds %d display limit"
                   max_distance)
          | None -> assert false)
      | Some ops ->
          let file_stats = stats_for_ops ops in
          let before_label = diff_label label text.before_state in
          let after_label = diff_label label text.after_state in
          add_file_header buffer mode ~before_label ~after_label;
          List.iter (render_hunk buffer mode) (hunks_of_ops ~context ops);
          file_stats)

let render_file_into ?limits ~context ~omitted buffer mode file =
  if is_noop file then empty_stats
  else
    render_file_text_into ?limits ~context ~omitted buffer mode file
      (file_text file)

let add_stats a b =
  {
    files = a.files + b.files;
    additions = a.additions + b.additions;
    deletions = a.deletions + b.deletions;
  }

let count_non_noop files =
  List.fold_left
    (fun count file -> if is_noop file then count else count + 1)
    0 files

let render ?(mode = `Display) ?limits ?(context = 3) files =
  let context = validate_context context in
  let buffer = Buffer.create 2048 in
  let omitted = ref 0 in
  let max_files = Option.map (fun limits -> limits.Limits.max_files) limits in
  let rec loop rendered stats = function
    | [] -> stats
    | file :: files when is_noop file -> loop rendered stats files
    | file :: files -> (
        match max_files with
        | Some max_files when rendered >= max_files ->
            let remaining = 1 + count_non_noop files in
            add_omission buffer
              (if remaining = 1 then "1 file exceeds max_files display limit"
               else
                 Printf.sprintf "%d files exceed max_files display limit"
                   remaining);
            omitted := !omitted + remaining;
            add_stats stats { files = remaining; additions = 0; deletions = 0 }
        | None | Some _ ->
            let file_stats =
              render_file_into ?limits ~context ~omitted buffer mode file
            in
            loop (rendered + 1) (add_stats stats file_stats) files)
  in
  let stats = loop 0 empty_stats files in
  { text = Buffer.contents buffer; stats; omitted = !omitted }

let stats_of_changes files =
  List.fold_left
    (fun stats file -> add_stats stats (stats_for_file file))
    empty_stats files

let stats t = t.stats
let omitted t = t.omitted
let to_string t = t.text
let is_empty t = Int.equal t.stats.files 0
