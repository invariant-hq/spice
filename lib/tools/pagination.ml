(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Count = struct
  type t = Exact of int | Lower_bound of int | Unknown
end

module Page = struct
  type 'req t = {
    returned : int;
    total : Count.t;
    offset : int;
    limit : int;
    next : 'req option;
    is_complete : bool;
  }

  let complete ~returned ~total ~offset ~limit =
    { returned; total; offset; limit; next = None; is_complete = true }

  let partial ~returned ~total ~offset ~limit ~next =
    { returned; total; offset; limit; next; is_complete = false }

  let returned t = t.returned
  let total t = t.total
  let offset t = t.offset
  let limit t = t.limit
  let is_complete t = t.is_complete
  let next t = t.next

  let encode_json json =
    match Jsont_bytesrw.encode_string Jsont.json json with
    | Ok text -> text
    | Error message ->
        invalid_arg ("could not encode continuation JSON: " ^ message)

  let hint ~tool ~to_json t =
    match t.next with
    | None -> None
    | Some req -> Some ("next: " ^ tool ^ " " ^ encode_json (to_json req))
end
