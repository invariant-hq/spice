(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_tool.Input." ^ fn ^ ": " ^ message)

(* [jsont] renders decode errors through a process-global styler that emits SGR
   escapes under an interactive [TERM]. Decode diagnostics are model-facing tool
   text, so strip any CSI escape at this one decode boundary rather than mutating
   the global styler. *)
let strip_ansi s =
  if not (String.contains s '\x1b') then s
  else begin
    let n = String.length s in
    let b = Buffer.create n in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '\x1b' && !i + 1 < n && s.[!i + 1] = '[' then begin
        i := !i + 2;
        (* CSI runs until a final byte in the range 0x40-0x7e. *)
        while !i < n && (s.[!i] < '\x40' || s.[!i] > '\x7e') do
          incr i
        done;
        if !i < n then incr i
      end
      else begin
        Buffer.add_char b s.[!i];
        incr i
      end
    done;
    Buffer.contents b
  end

let is_json_object = function
  | Jsont.Object _ -> true
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      false

let object_schema fields =
  let mem name value = Jsont.Json.mem (Jsont.Json.name name) value in
  Jsont.Json.object' (List.map (fun (name, value) -> mem name value) fields)

type 'a t = { codec : 'a Jsont.t; schema : Jsont.json }

let make codec ~schema =
  if not (is_json_object schema) then
    invalid "make" "schema must be a JSON object";
  { codec; schema }

let empty =
  let codec =
    Jsont.Object.map ~kind:"empty tool input" ()
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
  in
  make codec
    ~schema:
      (object_schema
         [
           ("type", Jsont.Json.string "object");
           ("properties", Jsont.Json.object' []);
           ("additionalProperties", Jsont.Json.bool false);
         ])

let schema t = t.schema

let decode t json =
  match Jsont.Json.decode t.codec json with
  | Ok _ as ok -> ok
  | Error diagnostic -> Error (strip_ansi diagnostic)
