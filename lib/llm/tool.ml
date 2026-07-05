(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_llm.Tool" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = function
  | None -> ()
  | Some value -> reject_empty fn field value

let is_name_first c = Char.Ascii.is_letter c || Char.equal c '_'

let is_name_rest c =
  is_name_first c || Char.Ascii.is_digit c || Char.equal c '-'

let reject_bad_name fn name =
  let len = String.length name in
  if len = 0 then invalid fn "name must not be empty";
  if len > 64 then invalid fn "name must be at most 64 characters";
  if not (is_name_first name.[0]) then
    invalid fn "name must start with an ASCII letter or '_'";
  for index = 1 to len - 1 do
    if not (is_name_rest name.[index]) then
      invalid fn "name must contain only ASCII letters, digits, '_', or '-'"
  done

let is_json_object = function
  | Jsont.Object _ -> true
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      false

let no_input_schema =
  Jsont.Json.object'
    [
      Jsont.Json.mem (Jsont.Json.name "type") (Jsont.Json.string "object");
      Jsont.Json.mem (Jsont.Json.name "properties") (Jsont.Json.object' []);
      Jsont.Json.mem
        (Jsont.Json.name "additionalProperties")
        (Jsont.Json.bool false);
    ]

type t = {
  name : string;
  description : string option;
  input_schema : Jsont.json;
}

let make ~name ?description ~input_schema () =
  reject_bad_name "make" name;
  reject_empty_option "make" "description" description;
  if not (is_json_object input_schema) then
    invalid "make" "input_schema must be a JSON object";
  { name; description; input_schema }

let name t = t.name
let description t = t.description
let input_schema t = t.input_schema

let jsont =
  let make name description input_schema =
    decode_invalid_arg (fun () -> make ~name ?description ~input_schema ())
  in
  Jsont.Object.map ~kind:"LLM tool declaration" make
  |> Jsont.Object.mem "name" Jsont.string ~enc:name
  |> Jsont.Object.opt_mem "description" Jsont.string ~enc:description
  |> Jsont.Object.mem "input_schema" Jsont.json ~enc:input_schema
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

module Call = struct
  type t = {
    id : string;
    name : string;
    input : Jsont.json;
    signature : string option;
  }

  let make ~id ~name ~input ?signature () =
    reject_empty "Call.make" "id" id;
    reject_bad_name "Call.make" name;
    (match signature with
    | Some signature -> reject_empty "Call.make" "signature" signature
    | None -> ());
    { id; name; input; signature }

  let id t = t.id
  let name (t : t) = t.name
  let input t = t.input
  let signature t = t.signature
  let equal a b = a = b

  let jsont =
    let make id name input signature =
      decode_invalid_arg (fun () -> make ~id ~name ~input ?signature ())
    in
    Jsont.Object.map ~kind:"tool call" make
    |> Jsont.Object.mem "id" Jsont.string ~enc:id
    |> Jsont.Object.mem "name" Jsont.string ~enc:name
    |> Jsont.Object.mem "input" Jsont.json ~enc:input
    |> Jsont.Object.opt_mem "signature" Jsont.string ~enc:signature
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Result = struct
  type t = {
    call_id : string;
    name : string;
    content : Content.t list;
    is_error : bool;
  }

  let make_raw ~call_id ~name ?(error = false) content =
    reject_empty "Result.make_raw" "call_id" call_id;
    reject_bad_name "Result.make_raw" name;
    { call_id; name; content; is_error = error }

  let make ?error call content =
    make_raw ~call_id:(Call.id call) ~name:(Call.name call) ?error content

  let empty ?error call = make ?error call []
  let text ?error call value = make ?error call [ Content.text value ]
  let call_id t = t.call_id
  let name (t : t) = t.name
  let content t = t.content

  let texts t =
    List.filter_map
      (function Content.Text text -> Some text | Content.Media _ -> None)
      t.content

  let is_error t = t.is_error
  let equal a b = a = b

  let jsont =
    let make call_id name error content =
      decode_invalid_arg (fun () -> make_raw ~call_id ~name ~error content)
    in
    Jsont.Object.map ~kind:"tool result" make
    |> Jsont.Object.mem "call_id" Jsont.string ~enc:call_id
    |> Jsont.Object.mem "name" Jsont.string ~enc:name
    |> Jsont.Object.mem "error" Jsont.bool ~enc:is_error
    |> Jsont.Object.mem "content" (Jsont.list Content.jsont) ~enc:content
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end
