(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = struct
  type kind =
    | Invalid_handle
    | Invalid_body
    | Invalid_syntax
    | Invalid_comment
    | Invalid_anchor
    | Stale_occurrence

  type t = { kind : kind; message : string }

  let make kind message = { kind; message }
  let kind t = t.kind
  let message t = t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

let error kind message = Error (Error.make kind message)
let is_space = Char.Ascii.is_white
let has_nul text = String.contains text '\000'
let slice text first last = String.sub text first (last - first)

let rec skip_space text i stop =
  if i < stop && is_space text.[i] then skip_space text (i + 1) stop else i

let starts_with_at text ~prefix ~at =
  let text_len = String.length text in
  let prefix_len = String.length prefix in
  at >= 0
  && at + prefix_len <= text_len
  &&
  let rec loop i =
    i = prefix_len || (Char.equal text.[at + i] prefix.[i] && loop (i + 1))
  in
  loop 0

let starts_with_in_slice text ~prefix ~at ~stop =
  at + String.length prefix <= stop && starts_with_at text ~prefix ~at

let contains_newline text =
  String.exists (function '\n' | '\r' -> true | _ -> false) text

let slice_equal text ~start ~stop expected =
  let len = stop - start in
  String.length expected = len
  &&
  let rec loop i =
    i = len || (Char.equal text.[start + i] expected.[i] && loop (i + 1))
  in
  loop 0

let splice text ~start ~stop ~replacement =
  let text_len = String.length text in
  if start = 0 && stop = text_len then replacement
  else
    let prefix = if start = 0 then "" else String.sub text 0 start in
    let suffix =
      if stop = text_len then "" else String.sub text stop (text_len - stop)
    in
    prefix ^ replacement ^ suffix

module Handle = struct
  type t = string

  let valid text =
    (not (String.is_empty text))
    && String.for_all
         (fun c -> not (is_space c || Char.equal c ':' || Char.equal c '\000'))
         text

  let of_string text =
    if valid text then Ok text
    else error Error.Invalid_handle "invalid CR handle"

  let to_string t = t
  let equal = String.equal
  let pp ppf t = Format.pp_print_string ppf t
end

module Priority = struct
  type t = Now | Soon

  let default = Now
  let equal a b = match (a, b) with Now, Now | Soon, Soon -> true | _ -> false
  let to_string = function Now -> "now" | Soon -> "soon"
  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

module Status = struct
  type t = Open of Priority.t | Resolved of { resolver : Handle.t }

  let equal a b =
    match (a, b) with
    | Open a, Open b -> Priority.equal a b
    | Resolved { resolver = a }, Resolved { resolver = b } -> Handle.equal a b
    | _ -> false

  let pp ppf = function
    | Open priority -> Format.fprintf ppf "open(%a)" Priority.pp priority
    | Resolved { resolver } ->
        Format.fprintf ppf "resolved(%a)" Handle.pp resolver
end

type t = { status : Status.t; recipient : Handle.t option; body : string }

let checked_body body =
  let body = String.trim body in
  if String.is_empty body then
    error Error.Invalid_body "CR body must not be empty"
  else if has_nul body then
    error Error.Invalid_body "CR body must not contain NUL"
  else Ok body

let make ?(priority = Priority.default) ?recipient ~body () =
  Result.map
    (fun body -> { status = Status.Open priority; recipient; body })
    (checked_body body)

let make_resolved ~resolver ~recipient ~body =
  Result.map
    (fun body -> { status = Status.Resolved { resolver }; recipient; body })
    (checked_body body)

let resolve ~resolver ?body t =
  let body = Option.value body ~default:t.body in
  make_resolved ~resolver ~recipient:t.recipient ~body

let status t = t.status
let recipient t = t.recipient
let body t = t.body

let priority_syntax = function
  | Priority.Now -> "CR"
  | Priority.Soon -> "CR-soon"

let to_string t =
  match (t.status, t.recipient) with
  | Status.Open priority, None -> priority_syntax priority ^ ": " ^ t.body
  | Status.Open priority, Some recipient ->
      priority_syntax priority ^ " " ^ Handle.to_string recipient ^ ": "
      ^ t.body
  | Status.Resolved { resolver }, None ->
      "XCR " ^ Handle.to_string resolver ^ ": " ^ t.body
  | Status.Resolved { resolver }, Some recipient ->
      "XCR " ^ Handle.to_string resolver ^ " for " ^ Handle.to_string recipient
      ^ ": " ^ t.body

let pp ppf t = Format.pp_print_string ppf (to_string t)
let digest t = Spice_digest.Identity.of_contents (to_string t)

let take_word text =
  let word, rest = String.cut_first_while (fun c -> not (is_space c)) text in
  (word, String.drop_first_while is_space rest)

let split_colon text =
  match String.split_first ~sep:":" text with
  | None -> error Error.Invalid_comment "CR is missing ':'"
  | Some (head, body) -> Ok (String.trim head, body)

let parse_handle text =
  match Handle.of_string text with
  | Ok _ as ok -> ok
  | Error _ -> error Error.Invalid_comment "invalid CR handle"

let parse_optional_recipient text =
  if String.is_empty text then Ok None
  else Result.map (fun recipient -> Some recipient) (parse_handle text)

let parse_priority = function
  | "CR" -> Ok Priority.Now
  | "CR-soon" -> Ok Priority.Soon
  | _ -> error Error.Invalid_comment "invalid CR kind"

let parse_resolved_recipient rest =
  if String.is_empty rest then Ok None
  else
    let marker, recipient_text = take_word rest in
    if String.equal marker "for" && not (String.is_empty recipient_text) then
      parse_optional_recipient recipient_text
    else error Error.Invalid_comment "invalid resolved CR recipient"

let parse_open text =
  Result.bind (split_colon text) (fun (head, body) ->
      let kind, recipient_text = take_word head in
      Result.bind (parse_priority kind) (fun priority ->
          Result.bind (parse_optional_recipient recipient_text)
            (fun recipient -> make ~priority ?recipient ~body ())))

let parse_resolved text =
  Result.bind (split_colon text) (fun (head, body) ->
      let kind, rest = take_word head in
      if not (String.equal kind "XCR") then
        error Error.Invalid_comment "invalid resolved CR kind"
      else
        let resolver_text, rest = take_word rest in
        Result.bind (parse_handle resolver_text) (fun resolver ->
            Result.bind (parse_resolved_recipient rest) (fun recipient ->
                make_resolved ~resolver ~recipient ~body)))

let parse text =
  let text = String.trim text in
  if String.starts_with ~prefix:"XCR" text then parse_resolved text
  else if String.starts_with ~prefix:"CR" text then parse_open text
  else error Error.Invalid_comment "not a CR"

let is_cr_like_slice text first last =
  let first = skip_space text first last in
  starts_with_in_slice text ~prefix:"CR" ~at:first ~stop:last
  || starts_with_in_slice text ~prefix:"XCR" ~at:first ~stop:last

module Syntax = struct
  type t =
    | Line of { prefix : string }
    | Block of { open_ : string; close : string }

  let valid_delimiter text =
    (not (String.is_empty text)) && not (has_nul text || contains_newline text)

  let valid_line_prefix text = valid_delimiter text && not (is_space text.[0])
  let ocaml = Block { open_ = "(*"; close = "*)" }

  let line ~prefix =
    if valid_line_prefix prefix then Ok (Line { prefix })
    else error Error.Invalid_syntax "invalid line comment syntax"

  let block ~open_ ~close =
    if valid_delimiter open_ && valid_delimiter close then
      Ok (Block { open_; close })
    else error Error.Invalid_syntax "invalid block comment syntax"

  let of_path path =
    let path = Spice_path.Rel.to_string path in
    let basename = Filename.basename path in
    let extension = Filename.extension basename in
    match (basename, extension) with
    | ("dune" | "dune-project" | "dune-workspace"), _ ->
        Some (Line { prefix = ";" })
    | _, (".ml" | ".mli" | ".mll" | ".mly") -> Some ocaml
    | _, (".js" | ".jsx" | ".ts" | ".tsx" | ".c" | ".h" | ".cc" | ".cpp")
    | _, (".hpp" | ".rs" | ".go" | ".java") ->
        Some (Line { prefix = "//" })
    | _, (".py" | ".sh" | ".rb" | ".yml" | ".yaml" | ".toml") ->
        Some (Line { prefix = "#" })
    | _, ".css" -> Some (Block { open_ = "/*"; close = "*/" })
    | _ -> None

  let equal a b =
    match (a, b) with
    | Line { prefix = a }, Line { prefix = b } -> String.equal a b
    | Block { open_ = ao; close = ac }, Block { open_ = bo; close = bc } ->
        String.equal ao bo && String.equal ac bc
    | _ -> false

  let pp ppf = function
    | Line { prefix } -> Format.fprintf ppf "line(%S)" prefix
    | Block { open_; close } -> Format.fprintf ppf "block(%S,%S)" open_ close
end

module Span = struct
  type t = { start_offset : int; stop_offset : int; line : int }

  let make ~start_offset ~stop_offset ~line =
    { start_offset; stop_offset; line }

  let start_offset t = t.start_offset
  let stop_offset t = t.stop_offset
  let line t = t.line

  let equal a b =
    Int.equal a.start_offset b.start_offset
    && Int.equal a.stop_offset b.stop_offset
    && Int.equal a.line b.line

  let pp ppf t =
    Format.fprintf ppf "line %d, bytes %d..%d" t.line t.start_offset
      t.stop_offset
end

module Occurrence = struct
  type cr = t

  type t = {
    path : Spice_path.Rel.t;
    syntax : Syntax.t;
    span : Span.t;
    raw : string;
    parsed : (cr, Error.t) result;
  }

  let make ~path ~syntax ~span ~raw ~payload =
    { path; syntax; span; raw; parsed = parse payload }

  let path t = t.path
  let syntax t = t.syntax
  let span t = t.span
  let line t = Span.line t.span
  let raw t = t.raw
  let comment t = t.parsed

  let digest t =
    match t.parsed with
    | Ok comment -> digest comment
    | Error _ -> Spice_digest.Identity.of_contents t.raw

  let equal a b =
    Spice_path.Rel.equal a.path b.path
    && Syntax.equal a.syntax b.syntax
    && Span.equal a.span b.span && String.equal a.raw b.raw

  let pp ppf t =
    Format.fprintf ppf "%a:%a:%S" Spice_path.Rel.pp t.path Span.pp t.span t.raw

  type counts = { open_ : int; addressed : int }

  let counts ~handle occurrences =
    List.fold_left
      (fun acc occurrence ->
        match comment occurrence with
        | Error _ -> acc
        | Ok cr -> (
            match status cr with
            | Status.Resolved _ -> acc
            | Status.Open _ ->
                let addressed =
                  match recipient cr with
                  | Some recipient when Handle.equal recipient handle ->
                      acc.addressed + 1
                  | Some _ | None -> acc.addressed
                in
                { open_ = acc.open_ + 1; addressed }))
      { open_ = 0; addressed = 0 }
      occurrences
end

let count_newlines text first last =
  let rec loop count i =
    if i >= last then count
    else
      let count = if Char.equal text.[i] '\n' then count + 1 else count in
      loop count (i + 1)
  in
  loop 0 first

let line_start_before text offset =
  let rec loop i =
    if i = 0 || Char.equal text.[i - 1] '\n' then i else loop (i - 1)
  in
  loop offset

let indentation_at text offset =
  let start = line_start_before text offset in
  let rec loop i =
    if i >= String.length text then slice text start i
    else
      match text.[i] with ' ' | '\t' -> loop (i + 1) | _ -> slice text start i
  in
  loop start

let make_occurrence ~path ~syntax ~text ~raw_start ~raw_stop ~payload_start
    ~payload_stop ~line =
  let span = Span.make ~start_offset:raw_start ~stop_offset:raw_stop ~line in
  Occurrence.make ~path ~syntax ~span
    ~raw:(slice text raw_start raw_stop)
    ~payload:(slice text payload_start payload_stop)

let string_literal_stop text start =
  let text_len = String.length text in
  let rec loop i =
    if i >= text_len then text_len
    else
      match text.[i] with
      | '\\' -> loop (min text_len (i + 2))
      | '"' -> i + 1
      | _ -> loop (i + 1)
  in
  loop (start + 1)

let is_quoted_string_id_char = function
  | '_' | '\'' -> true
  | c -> Char.Ascii.is_alphanum c

let quoted_string_stop text start =
  let text_len = String.length text in
  match
    String.find_first_index
      (fun c -> Char.equal c '|' || not (is_quoted_string_id_char c))
      ~start:(start + 1) text
  with
  | Some delimiter when Char.equal text.[delimiter] '|' -> (
      let id = slice text (start + 1) delimiter in
      let payload_start = delimiter + 1 in
      let close = "|" ^ id ^ "}" in
      match String.find_first ~sub:close ~start:payload_start text with
      | None -> Some text_len
      | Some close_start -> Some (close_start + String.length close))
  | None -> None
  | Some _ -> None

let find_ocaml_block_open ~open_ text start =
  let text_len = String.length text in
  let rec loop i =
    if i >= text_len then None
    else if Char.equal text.[i] '"' then loop (string_literal_stop text i)
    else if Char.equal text.[i] '{' then
      match quoted_string_stop text i with
      | None -> try_open i
      | Some stop -> loop stop
    else try_open i
  and try_open i =
    if starts_with_at text ~prefix:open_ ~at:i then Some i else loop (i + 1)
  in
  loop start

let scan_block ~path ~syntax ~open_ ~close text =
  let open_len = String.length open_ in
  let close_len = String.length close in
  let ocaml_block = String.equal open_ "(*" && String.equal close "*)" in
  let find_open =
    if ocaml_block then find_ocaml_block_open ~open_ text
    else fun start -> String.find_first ~sub:open_ ~start text
  in
  let block_stop payload_start =
    if not ocaml_block then
      String.find_first ~sub:close ~start:payload_start text
    else
      let rec loop depth offset =
        let next_open = String.find_first ~sub:open_ ~start:offset text in
        let next_close = String.find_first ~sub:close ~start:offset text in
        match (next_open, next_close) with
        | _, None -> None
        | Some open_start, Some close_start when open_start < close_start ->
            loop (depth + 1) (open_start + open_len)
        | _, Some close_start ->
            if depth = 1 then Some close_start
            else loop (depth - 1) (close_start + close_len)
      in
      loop 1 payload_start
  in
  let rec loop acc offset line =
    match find_open offset with
    | None -> List.rev acc
    | Some start -> (
        let line = line + count_newlines text offset start in
        let payload_start = start + open_len in
        match block_stop payload_start with
        | None -> List.rev acc
        | Some close_start ->
            let stop = close_start + close_len in
            let acc =
              if is_cr_like_slice text payload_start close_start then
                make_occurrence ~path ~syntax ~text ~raw_start:start
                  ~raw_stop:stop ~payload_start ~payload_stop:close_start ~line
                :: acc
              else acc
            in
            let next_offset = if ocaml_block then payload_start else stop in
            loop acc next_offset (line + count_newlines text start next_offset))
  in
  loop [] 0 1

let scan_line ~path ~syntax ~prefix text =
  let prefix_len = String.length prefix in
  let text_len = String.length text in
  let rec loop acc line line_start offset =
    if offset > text_len then List.rev acc
    else if offset = text_len || Char.equal text.[offset] '\n' then
      let line_stop =
        if offset > line_start && Char.equal text.[offset - 1] '\r' then
          offset - 1
        else offset
      in
      let comment_start = skip_space text line_start line_stop in
      let acc =
        if starts_with_in_slice text ~prefix ~at:comment_start ~stop:line_stop
        then
          let payload_start = comment_start + prefix_len in
          if is_cr_like_slice text payload_start line_stop then
            make_occurrence ~path ~syntax ~text ~raw_start:comment_start
              ~raw_stop:line_stop ~payload_start ~payload_stop:line_stop ~line
            :: acc
          else acc
        else acc
      in
      loop acc (line + 1) (offset + 1) (offset + 1)
    else loop acc line line_start (offset + 1)
  in
  loop [] 1 0 0

let scan ~syntax ~path ~text =
  match syntax with
  | Syntax.Line { prefix } -> scan_line ~path ~syntax ~prefix text
  | Syntax.Block { open_; close } -> scan_block ~path ~syntax ~open_ ~close text

let scan_file ~path ~text =
  match Syntax.of_path path with
  | None -> []
  | Some syntax -> scan ~syntax ~path ~text

let render ~syntax cr =
  let text = to_string cr in
  match syntax with
  | Syntax.Line { prefix } ->
      if contains_newline text then
        error Error.Invalid_body "CR body cannot be rendered as a line comment"
      else Ok (prefix ^ " " ^ text)
  | Syntax.Block { open_; close } ->
      let includes_delimiter =
        String.includes ~affix:close text
        || String.equal open_ "(*" && String.equal close "*)"
           && String.includes ~affix:open_ text
      in
      if contains_newline text || includes_delimiter then
        error Error.Invalid_body "CR body cannot be rendered as a block comment"
      else Ok (open_ ^ " " ^ text ^ " " ^ close)

let line_offset text line =
  if line < 1 then error Error.Invalid_anchor "line must be at least 1"
  else if line = 1 then Ok 0
  else
    let text_len = String.length text in
    let rec loop current i =
      if current = line then Ok i
      else if i = text_len then
        error Error.Invalid_anchor "line is outside source"
      else if Char.equal text.[i] '\n' then loop (current + 1) (i + 1)
      else loop current (i + 1)
    in
    loop 1 0

let line_end_after text line =
  match line_offset text line with
  | Error _ as error -> error
  | Ok start ->
      let text_len = String.length text in
      let rec loop i =
        if i = text_len then Ok i
        else if Char.equal text.[i] '\n' then Ok (i + 1)
        else loop (i + 1)
      in
      loop start

let inserted_comment text offset comment =
  let needs_leading_newline =
    offset > 0 && not (Char.equal text.[offset - 1] '\n')
  in
  let indentation =
    if offset = String.length text then "" else indentation_at text offset
  in
  (if needs_leading_newline then "\n" else "") ^ indentation ^ comment ^ "\n"

let add_at_offset ~syntax ~text offset cr =
  match render ~syntax cr with
  | Error _ as error -> error
  | Ok comment ->
      let replacement = inserted_comment text offset comment in
      Ok (splice text ~start:offset ~stop:offset ~replacement)

let add_before_line ~syntax ~text ~line cr =
  match line_offset text line with
  | Error _ as error -> error
  | Ok offset -> add_at_offset ~syntax ~text offset cr

let add_after_line ~syntax ~text ~line cr =
  match line_end_after text line with
  | Error _ as error -> error
  | Ok offset -> add_at_offset ~syntax ~text offset cr

let add_at_end ~syntax ~text cr =
  add_at_offset ~syntax ~text (String.length text) cr

let replace_range ~text ~start ~stop ~expected ~replacement =
  if start < 0 || stop < start || stop > String.length text then
    error Error.Stale_occurrence "source occurrence is stale"
  else if not (slice_equal text ~start ~stop expected) then
    error Error.Stale_occurrence "source occurrence is stale"
  else Ok (splice text ~start ~stop ~replacement)

let replace ~text occurrence cr =
  match render ~syntax:(Occurrence.syntax occurrence) cr with
  | Error _ as error -> error
  | Ok replacement ->
      let span = Occurrence.span occurrence in
      replace_range ~text ~start:(Span.start_offset span)
        ~stop:(Span.stop_offset span)
        ~expected:(Occurrence.raw occurrence)
        ~replacement

(* Removing a comment that is alone on its line(s) removes the lines —
   indentation, trailing whitespace, and line ending included — which is what
   a human deleting the comment would leave behind. A comment sharing a line
   with code removes only its span. *)
let remove ~text occurrence =
  let span = Occurrence.span occurrence in
  let start = Span.start_offset span in
  let stop = Span.stop_offset span in
  let length = String.length text in
  if start < 0 || stop < start || stop > length then
    error Error.Stale_occurrence "source occurrence is stale"
  else if not (slice_equal text ~start ~stop (Occurrence.raw occurrence)) then
    error Error.Stale_occurrence "source occurrence is stale"
  else
    let is_blank char = Char.equal char ' ' || Char.equal char '\t' in
    let line_start =
      let rec back i =
        if i = 0 then 0
        else if Char.equal text.[i - 1] '\n' then i
        else back (i - 1)
      in
      back start
    in
    let alone_before =
      let rec check i =
        i <= line_start || (is_blank text.[i - 1] && check (i - 1))
      in
      check start
    in
    let line_stop =
      let rec forward i =
        if i >= length then Some length
        else if Char.equal text.[i] '\n' then Some (i + 1)
        else if
          Char.equal text.[i] '\r'
          && i + 1 < length
          && Char.equal text.[i + 1] '\n'
        then Some (i + 2)
        else if is_blank text.[i] then forward (i + 1)
        else None
      in
      forward stop
    in
    match (alone_before, line_stop) with
    | true, Some line_stop ->
        Ok (splice text ~start:line_start ~stop:line_stop ~replacement:"")
    | _ -> Ok (splice text ~start ~stop ~replacement:"")
