(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type interval = {
  mutable started_ms : float option;
  mutable finished_ms : float option;
}

type t = (string, interval) Hashtbl.t

let empty : t = Hashtbl.create 1

let decode_json line =
  match Jsont_bytesrw.decode_string Jsont.json line with
  | Ok json -> Some json
  | Error _ -> None

let member name = function
  | Jsont.Object (mems, _) -> Option.map snd (Jsont.Json.find_mem name mems)
  | _ -> None

let string_member name json =
  match member name json with Some (Jsont.String (s, _)) -> Some s | _ -> None

let int_member name json =
  match member name json with
  | Some (Jsont.Number (n, _)) when Float.is_integer n -> Some (int_of_float n)
  | _ -> None

(* Line N of the timing sidecar stamps the Nth newline-terminated line of
   [agent.jsonl]. Splitting on ['\n'] yields a trailing empty element after the
   final newline; it carries no stamp and decodes to nothing, so 1-based
   indices of the split list line up with the sidecar's [line] numbers. *)
let stamps timing_jsonl =
  let table = Hashtbl.create 256 in
  String.split_on_char '\n' timing_jsonl
  |> List.iter (fun raw ->
      match decode_json raw with
      | None -> ()
      | Some json -> (
          match (int_member "line" json, int_member "ts_ms" json) with
          | Some line, Some ts -> Hashtbl.replace table line (float_of_int ts)
          | _ -> ()));
  table

let interval table id =
  match Hashtbl.find_opt table id with
  | Some interval -> interval
  | None ->
      let interval = { started_ms = None; finished_ms = None } in
      Hashtbl.replace table id interval;
      interval

let of_artifacts ~agent_jsonl ~timing_jsonl =
  let stamps = stamps timing_jsonl in
  let table : t = Hashtbl.create 256 in
  let lines = String.split_on_char '\n' agent_jsonl in
  List.iteri
    (fun index raw ->
      let line_no = index + 1 in
      match decode_json raw with
      | None -> ()
      | Some json -> (
          match
            (string_member "type" json, Hashtbl.find_opt stamps line_no)
          with
          | Some "tool.started", Some ts -> (
              match string_member "tool_call_id" json with
              | Some id ->
                  let entry = interval table id in
                  if Option.is_none entry.started_ms then
                    entry.started_ms <- Some ts
              | None -> ())
          | Some "tool.finished", Some ts -> (
              match string_member "tool_call_id" json with
              | Some id -> (interval table id).finished_ms <- Some ts
              | None -> ())
          | _ -> ()))
    lines;
  table

let call_interval t ~tool_call_id =
  match Hashtbl.find_opt t tool_call_id with
  | Some { started_ms = Some s; finished_ms = Some f } -> Some (s, f)
  | Some _ | None -> None
