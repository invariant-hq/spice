(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_tool.Output." ^ fn ^ ": " ^ message)

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let decode_invalid_arg f =
  match f () with
  | value -> value
  | exception Invalid_argument message ->
      Jsont.Error.msg Jsont.Meta.none message

type value = Value : 'a Type.Id.t * 'a -> value

type t = {
  text : string;
  json : Jsont.json option;
  truncated : bool;
  value : value option;
}

type 'a encoder = 'a -> t

let pack id value = Value (id, value)

let make ~text ?json ?(truncated = false) ?value () =
  reject_empty "make" "text" text;
  { text; json; truncated; value }

let text t = t.text
let json t = t.json
let truncated t = t.truncated

let equal a b =
  String.equal a.text b.text
  && Option.equal Jsont.Json.equal a.json b.json
  && Bool.equal a.truncated b.truncated

let jsont =
  let make text json truncated =
    decode_invalid_arg (fun () -> make ~text ?json ~truncated ())
  in
  Jsont.Object.map ~kind:"tool output" make
  |> Jsont.Object.mem "text" Jsont.string ~enc:text
  |> Jsont.Object.opt_mem "json" Jsont.json ~enc:json
  |> Jsont.Object.mem "truncated" Jsont.bool ~enc:truncated
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let value (type a) (id : a Type.Id.t) t : a option =
  match t.value with
  | None -> None
  | Some (Value (packed_id, packed)) -> (
      match Type.Id.provably_equal packed_id id with
      | Some Type.Equal -> Some packed
      | None -> None)
