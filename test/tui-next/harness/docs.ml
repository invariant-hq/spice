(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Read-side introspection of seeded/persisted session documents. *)

module Json = Jsont.Json

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let required_object_field object_name name json =
  match object_field name json with
  | Some value -> value
  | None -> Util.failf "%s.%s missing" object_name name

let required_string_field object_name name json =
  match required_object_field object_name name json with
  | Jsont.String (value, _) -> value
  | value ->
      Util.failf "%s.%s must be string, got %s" object_name name
        (Result.get_ok (Jsont_bytesrw.encode_string Jsont.json value))

let required_int_field object_name name json =
  match Json.decode Jsont.int (required_object_field object_name name json) with
  | Ok value -> value
  | Error _ -> Util.failf "%s.%s must be int" object_name name

type session_doc = {
  id : string;
  event_count : int;
  forked_from : (string * int) option;
}

let session_doc_of_json json =
  let id = required_string_field "session" "id" json in
  let event_count =
    match required_object_field "session" "events" json with
    | Jsont.Array (events, _) -> List.length events
    | value ->
        Util.failf "session.events must be array, got %s"
          (Result.get_ok (Jsont_bytesrw.encode_string Jsont.json value))
  in
  let metadata = required_object_field "session" "metadata" json in
  let forked_from =
    match object_field "forked_from" metadata with
    | None | Some (Jsont.Null _) -> None
    | Some fork ->
        Some
          ( required_string_field "forked_from" "parent" fork,
            required_int_field "forked_from" "copied_events" fork )
  in
  { id; event_count; forked_from }

let session_docs project =
  let root = Project.path project ".spice/sessions" in
  if not (Sys.file_exists root && Sys.is_directory root) then []
  else
    Sys.readdir root |> Array.to_list |> List.sort String.compare
    |> List.filter_map (fun id ->
        let path = Filename.concat (Filename.concat root id) "session.json" in
        if Sys.file_exists path then
          match
            Jsont_bytesrw.decode_string Jsont.json (Util.read_file path)
          with
          | Ok json -> Some (session_doc_of_json json)
          | Error message -> Util.failf "%s: %s" path message
        else None)

let event_count project id =
  match
    List.find_opt (fun doc -> String.equal doc.id id) (session_docs project)
  with
  | Some doc -> doc.event_count
  | None -> Util.failf "session %s not found" id
