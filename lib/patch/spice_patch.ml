(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type t =
    | Invalid_patch of { line : int option; message : string }
    | Invalid_hunk of { line : int; message : string }
    | Empty_patch of { line : int }
    | Empty_update of { line : int }
    | Invalid_path of { line : int; input : string; error : Spice_path.Error.t }

  let at line message = Printf.sprintf "line %d: %s" line message

  let message = function
    | Invalid_patch { line = Some line; message } -> at line message
    | Invalid_patch { line = None; message } -> message
    | Invalid_hunk { line; message } -> at line message
    | Empty_patch { line } -> at line "patch contains no operations"
    | Empty_update { line } -> at line "update file hunk must not be empty"
    | Invalid_path { line; input; error } ->
        at line
          (Printf.sprintf "invalid patch path %S: %s" input
             (Spice_path.Error.message error))

  let pp ppf t = Format.pp_print_string ppf (message t)
end

module Rel = Spice_path.Rel

let invalid_patch ?line message = Error (Error.Invalid_patch { line; message })
let invalid_hunk ~line message = Error (Error.Invalid_hunk { line; message })
let empty_patch ~line = Error (Error.Empty_patch { line })
let empty_update ~line = Error (Error.Empty_update { line })

let invalid_path ~line input path_error =
  Error (Error.Invalid_path { line; input; error = path_error })

let begin_patch_marker = "*** Begin Patch"
let end_patch_marker = "*** End Patch"
let add_file_marker = "*** Add File: "
let delete_file_marker = "*** Delete File: "
let update_file_marker = "*** Update File: "
let move_to_marker = "*** Move to: "
let eof_marker = "*** End of File"
let context_marker = "@@ "
let empty_context_marker = "@@"

let split_lines text =
  let len = String.length text in
  let line start stop =
    let stop =
      if stop > start && Char.equal text.[stop - 1] '\r' then stop - 1 else stop
    in
    String.sub text start (stop - start)
  in
  let rec loop acc start i =
    if i = len then
      if start = len then List.rev acc else List.rev (line start i :: acc)
    else if Char.equal text.[i] '\n' then
      loop (line start i :: acc) (i + 1) (i + 1)
    else loop acc start (i + 1)
  in
  loop [] 0 0

module Update = struct
  module Error = struct
    type mismatch =
      | Missing_context of string
      | Missing_lines of { old_lines : string list; end_of_file : bool }
      | Missing_insertion_point of { end_of_file : bool }

    type t = { chunk : int; mismatch : mismatch }

    let make ~chunk mismatch = { chunk; mismatch }
    let chunk t = t.chunk
    let mismatch t = t.mismatch

    let mismatch_message = function
      | Missing_context line -> Printf.sprintf "missing context %S" line
      | Missing_lines { old_lines; end_of_file } ->
          let eof = if end_of_file then " at end of file" else "" in
          Printf.sprintf "missing lines%s: %S" eof
            (String.concat "\\n" old_lines)
      | Missing_insertion_point { end_of_file } ->
          let eof = if end_of_file then " at end of file" else "" in
          Printf.sprintf "missing insertion point%s" eof

    let message t =
      Printf.sprintf "patch chunk %d failed: %s" t.chunk
        (mismatch_message t.mismatch)

    let pp ppf t = Format.pp_print_string ppf (message t)
  end

  type chunk = {
    context : string option;
    old_lines : string list;
    new_lines : string list;
    end_of_file : bool;
  }

  type t = { chunks : chunk list }

  let make chunks = { chunks }
  let chunks t = t.chunks

  type text = { lines : string array; trailing_newline : bool }

  let text_lines text =
    if String.is_empty text then { lines = [||]; trailing_newline = false }
    else
      let trailing_newline = String.ends_with ~suffix:"\n" text in
      let text = if trailing_newline then String.drop_last 1 text else text in
      let lines =
        if String.is_empty text then [| "" |]
        else Array.of_list (String.split_on_char '\n' text)
      in
      { lines; trailing_newline }

  let join_lines text =
    if Array.length text.lines = 0 then ""
    else
      let contents = String.concat "\n" (Array.to_list text.lines) in
      if text.trailing_newline then contents ^ "\n" else contents

  let find_sequence ~from pattern lines =
    let from = max 0 from in
    let pattern = Array.of_list pattern in
    let pattern_len = Array.length pattern in
    let lines_len = Array.length lines in
    if pattern_len = 0 then if from <= lines_len then Some from else None
    else
      let matches_at i =
        let rec loop j =
          j = pattern_len
          || (String.equal lines.(i + j) pattern.(j) && loop (j + 1))
        in
        loop 0
      in
      let rec loop i =
        if i + pattern_len > lines_len then None
        else if matches_at i then Some i
        else loop (i + 1)
      in
      loop from

  let replace_at index old_len new_lines lines =
    let new_lines = Array.of_list new_lines in
    let new_len = Array.length new_lines in
    let lines_len = Array.length lines in
    let suffix_start = index + old_len in
    let suffix_len = lines_len - suffix_start in
    let result = Array.make (lines_len - old_len + new_len) "" in
    Array.blit lines 0 result 0 index;
    Array.blit new_lines 0 result index new_len;
    Array.blit lines suffix_start result (index + new_len) suffix_len;
    result

  let apply_chunk line_index text chunk =
    let lines = text.lines in
    let has_context = Option.is_some chunk.context in
    let line_index_result =
      match chunk.context with
      | None -> Ok line_index
      | Some context -> (
          match find_sequence ~from:line_index [ context ] lines with
          | Some index -> Ok (index + 1)
          | None -> Error (Error.Missing_context context))
    in
    match line_index_result with
    | Error _ as error -> error
    | Ok line_index -> (
        let found =
          if List.is_empty chunk.old_lines then
            if chunk.end_of_file then
              if not has_context then Some (Array.length lines)
              else if line_index = Array.length lines then Some line_index
              else None
            else if not has_context then Some (Array.length lines)
            else Some line_index
          else if chunk.end_of_file then
            let old_len = List.length chunk.old_lines in
            let start = Array.length lines - old_len in
            if
              start >= line_index
              && Option.equal Int.equal
                   (find_sequence ~from:start chunk.old_lines lines)
                   (Some start)
            then Some start
            else None
          else find_sequence ~from:line_index chunk.old_lines lines
        in
        match found with
        | None ->
            if List.is_empty chunk.old_lines then
              Error
                (Error.Missing_insertion_point
                   { end_of_file = chunk.end_of_file })
            else
              Error
                (Error.Missing_lines
                   {
                     old_lines = chunk.old_lines;
                     end_of_file = chunk.end_of_file;
                   })
        | Some index ->
            let lines =
              replace_at index
                (List.length chunk.old_lines)
                chunk.new_lines lines
            in
            Ok (index + List.length chunk.new_lines, { text with lines }))

  let apply t contents =
    let rec loop chunk_index line_index text = function
      | [] -> Ok (join_lines text)
      | chunk :: chunks -> (
          match apply_chunk line_index text chunk with
          | Error mismatch -> Error (Error.make ~chunk:chunk_index mismatch)
          | Ok (line_index, text) ->
              loop (chunk_index + 1) line_index text chunks)
    in
    loop 0 0 (text_lines contents) t.chunks
end

module Operation = struct
  type t =
    | Add of { path : Rel.t; contents : string }
    | Delete of { path : Rel.t }
    | Update of { path : Rel.t; move_to : Rel.t option; update : Update.t }

  let path = function
    | Add { path; _ } | Delete { path } | Update { path; _ } -> path

  let output_path = function
    | Add { path; _ } | Delete { path } -> path
    | Update { path; move_to = None; _ } -> path
    | Update { move_to = Some path; _ } -> path
end

let parse_path ~line text =
  let input = String.trim text in
  match Rel.of_string input with
  | Ok path -> Ok path
  | Error path_error -> invalid_path ~line input path_error

let parse_add path lines line_index =
  let rec loop contents parsed = function
    | line :: rest when String.starts_with ~prefix:"+" line ->
        loop (String.drop_first 1 line :: contents) (parsed + 1) rest
    | rest -> (List.rev contents, parsed, rest)
  in
  let contents, parsed, rest = loop [] 0 lines in
  if parsed = 0 then
    invalid_hunk ~line:line_index "add file hunk must contain at least one line"
  else
    Ok
      ( Operation.Add { path; contents = String.concat "\n" contents ^ "\n" },
        parsed + 1,
        rest )

let is_hunk_header line =
  let line = String.trim line in
  String.starts_with ~prefix:add_file_marker line
  || String.starts_with ~prefix:delete_file_marker line
  || String.starts_with ~prefix:update_file_marker line
  || String.equal line end_patch_marker

let is_eof_marker line = String.equal (String.trim line) eof_marker

let is_update_line line =
  (not (String.is_empty line)) && match line.[0] with
  | ' ' | '+' | '-' -> true
  | _ -> false

let parse_chunk lines line_index allow_missing_context =
  let context_result =
    match lines with
    | [] -> Ok (None, 0)
    | line :: _ when String.equal line empty_context_marker -> Ok (None, 1)
    | line :: _ when String.starts_with ~prefix:context_marker line ->
        Ok (Some (String.drop_first (String.length context_marker) line), 1)
    | line :: _
      when allow_missing_context
           && (is_update_line line || not (is_hunk_header line)) ->
        Ok (None, 0)
    | line :: _ ->
        let message =
          Printf.sprintf "expected update chunk to start with @@, got %S" line
        in
        invalid_hunk ~line:line_index message
  in
  match context_result with
  | Error _ as error -> error
  | Ok (context, start_index) -> (
      let invalid_update_line line parsed =
        let message =
          Printf.sprintf
            "unexpected line in update hunk: %S; expected space, +, or -" line
        in
        invalid_hunk ~line:(line_index + start_index + parsed) message
      in
      let rec loop old_lines new_lines end_of_file parsed = function
        | [] -> Ok (old_lines, new_lines, end_of_file, parsed, [])
        | line :: rest -> (
            if String.is_empty line then invalid_update_line line parsed
            else
              let data = String.drop_first 1 line in
              match line.[0] with
              | ' ' ->
                  loop (data :: old_lines) (data :: new_lines) end_of_file
                    (parsed + 1) rest
              | '+' ->
                  loop old_lines (data :: new_lines) end_of_file (parsed + 1)
                    rest
              | '-' ->
                  loop (data :: old_lines) new_lines end_of_file (parsed + 1)
                    rest
              | _ ->
                  if is_eof_marker line then
                    Ok (old_lines, new_lines, true, parsed + 1, rest)
                  else if is_hunk_header line then
                    Ok (old_lines, new_lines, end_of_file, parsed, line :: rest)
                  else if
                    parsed > 0
                    && (String.equal line empty_context_marker
                       || String.starts_with ~prefix:context_marker line)
                  then
                    Ok (old_lines, new_lines, end_of_file, parsed, line :: rest)
                  else if parsed = 0 then invalid_update_line line parsed
                  else
                    Ok (old_lines, new_lines, end_of_file, parsed, line :: rest)
            )
      in
      let result = loop [] [] false 0 (List.drop start_index lines) in
      match result with
      | Error _ as error -> error
      | Ok (old_lines, new_lines, end_of_file, parsed_lines, rest) ->
          if List.is_empty old_lines && List.is_empty new_lines then
            empty_update ~line:(line_index + start_index)
          else
            Ok
              ( {
                  Update.context;
                  old_lines = List.rev old_lines;
                  new_lines = List.rev new_lines;
                  end_of_file;
                },
                start_index + parsed_lines,
                rest ))

let parse_update path lines line_index =
  let move_to, lines, parsed_move =
    match lines with
    | line :: rest
      when String.starts_with ~prefix:move_to_marker (String.trim line) ->
        let path_text =
          String.drop_first (String.length move_to_marker) (String.trim line)
        in
        (Some path_text, rest, 1)
    | _ -> (None, lines, 0)
  in
  match
    match move_to with
    | None -> Ok None
    | Some path ->
        Result.map Option.some (parse_path ~line:(line_index + 1) path)
  with
  | Error _ as error -> error
  | Ok move_to -> (
      let rec loop chunks parsed lines =
        match lines with
        | [] -> Ok (List.rev chunks, parsed, [])
        | line :: _ when is_hunk_header line ->
            Ok (List.rev chunks, parsed, lines)
        | line :: rest when String.equal (String.trim line) "" ->
            loop chunks (parsed + 1) rest
        | _ -> (
            match
              parse_chunk lines (line_index + parsed) (List.is_empty chunks)
            with
            | Ok (chunk, chunk_lines, rest) ->
                loop (chunk :: chunks) (parsed + chunk_lines) rest
            | Error _ as error -> error)
      in
      match loop [] (1 + parsed_move) lines with
      | Error _ as error -> error
      | Ok ([], _, _) -> empty_update ~line:line_index
      | Ok (chunks, parsed, rest) ->
          Ok
            ( Operation.Update { path; move_to; update = Update.make chunks },
              parsed,
              rest ))

let parse_operation lines line_index =
  match lines with
  | [] -> invalid_patch "unexpected end of patch"
  | line :: rest ->
      let header = String.trim line in
      if String.starts_with ~prefix:add_file_marker header then
        match
          parse_path ~line:line_index
            (String.drop_first (String.length add_file_marker) header)
        with
        | Error _ as error -> error
        | Ok path -> parse_add path rest line_index
      else if String.starts_with ~prefix:delete_file_marker header then
        match
          parse_path ~line:line_index
            (String.drop_first (String.length delete_file_marker) header)
        with
        | Error _ as error -> error
        | Ok path -> Ok (Operation.Delete { path }, 1, rest)
      else if String.starts_with ~prefix:update_file_marker header then
        match
          parse_path ~line:line_index
            (String.drop_first (String.length update_file_marker) header)
        with
        | Error _ as error -> error
        | Ok path -> parse_update path rest line_index
      else
        invalid_hunk ~line:line_index
          "expected add, delete, or update file hunk"

let parse text =
  let lines = split_lines text in
  match lines with
  | [] -> invalid_patch "patch is empty"
  | first :: _ when not (String.equal (String.trim first) begin_patch_marker) ->
      invalid_patch ~line:1 "first line must be '*** Begin Patch'"
  | _ -> (
      let rec collect acc line_index = function
        | [] -> invalid_patch "last line must be '*** End Patch'"
        | line :: rest when String.equal (String.trim line) end_patch_marker ->
            if not (List.is_empty rest) then
              invalid_patch ~line:(line_index + 1)
                "last line must be '*** End Patch'"
            else if List.is_empty acc then empty_patch ~line:line_index
            else Ok (List.rev acc)
        | lines -> (
            match parse_operation lines line_index with
            | Error _ as error -> error
            | Ok (operation, consumed, rest) ->
                collect (operation :: acc) (line_index + consumed) rest)
      in
      match lines with [] -> assert false | _ :: lines -> collect [] 2 lines)
