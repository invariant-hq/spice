(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Dune = Spice_ocaml_dune
module Ocaml = Spice_ocaml

let name = "ocaml_dune_diagnostics"
let description = Spice_prompts.Tools.ocaml_dune_diagnostics
let request_timeout_s = 1.0

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

let json_string_option = function
  | None -> json_null
  | Some value -> Json.string value

let permissions workspace =
  [
    Permission.Request.of_accesses ~source:name
      [ Permission.Access.path ~op:`Read (Workspace.root_path workspace) ];
  ]

let path_json path = Json.string (Workspace.Path.display path)

let location_json location =
  let range = Ocaml.Location.range location in
  let position_json position =
    json_obj
      [
        ("line", Json.int (Ocaml.Position.line position));
        ("column", Json.int (Ocaml.Position.column position));
      ]
  in
  json_obj
    [
      ("path", path_json (Ocaml.Location.path location));
      ( "range",
        json_obj
          [
            ("start", position_json (Ocaml.Range.start range));
            ("end", position_json (Ocaml.Range.end_ range));
          ] );
    ]

let severity_text = function
  | Ocaml.Diagnostic.Severity.Error -> "error"
  | Ocaml.Diagnostic.Severity.Warning -> "warning"
  | Ocaml.Diagnostic.Severity.Information -> "information"
  | Ocaml.Diagnostic.Severity.Hint -> "hint"

let tag_text = function
  | Ocaml.Diagnostic.Tag.Unnecessary -> "unnecessary"
  | Ocaml.Diagnostic.Tag.Deprecated -> "deprecated"

let related_json related =
  json_obj
    [
      ("message", Json.string (Ocaml.Diagnostic.Related.message related));
      ( "location",
        match Ocaml.Diagnostic.Related.location related with
        | None -> json_null
        | Some location -> location_json location );
    ]

let diagnostic_json (id, diagnostic) =
  json_obj
    [
      ("id", Json.string (Dune.Rpc.Diagnostic.Id.to_string id));
      ("message", Json.string (Ocaml.Diagnostic.message diagnostic));
      ( "source",
        Json.string
          (Ocaml.Diagnostic.Source.to_string
             (Ocaml.Diagnostic.source diagnostic)) );
      ( "severity",
        Json.string (severity_text (Ocaml.Diagnostic.severity diagnostic)) );
      ("code", json_string_option (Ocaml.Diagnostic.code diagnostic));
      ( "location",
        match Ocaml.Diagnostic.location diagnostic with
        | None -> json_null
        | Some location -> location_json location );
      ( "tags",
        Json.list
          (List.map
             (fun tag -> Json.string (tag_text tag))
             (Ocaml.Diagnostic.tags diagnostic)) );
      ( "related",
        Json.list (List.map related_json (Ocaml.Diagnostic.related diagnostic))
      );
    ]

let diagnostic_location_text diagnostic =
  match Ocaml.Diagnostic.location diagnostic with
  | None -> "<workspace>"
  | Some location ->
      let range = Ocaml.Location.range location in
      let start = Ocaml.Range.start range in
      Printf.sprintf "%s:%d:%d"
        (Workspace.Path.display (Ocaml.Location.path location))
        (Ocaml.Position.line start)
        (Ocaml.Position.column start)

let diagnostic_line (id, diagnostic) =
  Printf.sprintf "- [%s] %s %s: %s (%s)"
    (severity_text (Ocaml.Diagnostic.severity diagnostic))
    (Ocaml.Diagnostic.Source.to_string (Ocaml.Diagnostic.source diagnostic))
    (diagnostic_location_text diagnostic)
    (Ocaml.Diagnostic.message diagnostic)
    (Dune.Rpc.Diagnostic.Id.to_string id)

module Output = struct
  type t = {
    endpoint : Dune.Rpc.Endpoint.t;
    diagnostics : (Dune.Rpc.Diagnostic.id * Ocaml.Diagnostic.t) list;
  }

  let make ~endpoint ~diagnostics = { endpoint; diagnostics }
  let endpoint t = t.endpoint
  let endpoint_text t = Dune.Rpc.Endpoint.to_string t.endpoint
  let diagnostics t = t.diagnostics
  let diagnostic_count t = List.length t.diagnostics
  let type_id : t Type.Id.t = Type.Id.make ()

  let json t =
    json_obj
      [
        ("endpoint", Json.string (Dune.Rpc.Endpoint.to_string t.endpoint));
        ("diagnostics", Json.list (List.map diagnostic_json t.diagnostics));
      ]

  let text t =
    match t.diagnostics with
    | [] ->
        Printf.sprintf "OCaml Dune diagnostics: none\nendpoint: %s"
          (Dune.Rpc.Endpoint.to_string t.endpoint)
    | diagnostics ->
        let b = Buffer.create 512 in
        Buffer.add_string b
          (Printf.sprintf "OCaml Dune diagnostics: %d\nendpoint: %s\n"
             (List.length diagnostics)
             (Dune.Rpc.Endpoint.to_string t.endpoint));
        List.iter
          (fun diagnostic ->
            Buffer.add_string b (diagnostic_line diagnostic);
            Buffer.add_char b '\n')
          diagnostics;
        String.trim (Buffer.contents b)

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let output ~endpoint diagnostics =
  Output.make ~endpoint
    ~diagnostics:(Dune.Rpc.Diagnostic.Store.to_list diagnostics)

let run ~clock ~dune ctx () =
  if Tool.Context.cancelled ctx then
    Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()
  else
    match Dune.Rpc.Instance.refresh dune with
    | Error error -> Tool.Result.failed `Unavailable (Dune.Error.message error)
    | Ok None ->
        Tool.Result.failed `Unavailable
          "no running Dune RPC instance was found for this workspace"
    | Ok (Some endpoint) -> (
        match
          Eio.Time.with_timeout_exn clock request_timeout_s (fun () ->
              Dune.Rpc.Instance.request_visible_diagnostics dune)
        with
        | Ok (endpoint, diagnostics) ->
            Tool.Result.completed ~output:(output ~endpoint diagnostics) ()
        | exception Eio.Time.Timeout ->
            Tool.Result.completed
              ~output:(output ~endpoint (Dune.Rpc.Instance.diagnostics dune))
              ()
        | Error error ->
            Tool.Result.failed `Unavailable (Dune.Error.message error))

let tool ~clock ~dune () =
  let workspace = Dune.Rpc.Instance.workspace dune in
  Tool.make ~name ~description ~input:Tool.Input.empty ~output:Output.encode
    ~permissions:(fun () -> permissions workspace)
    ~run:(run ~clock ~dune) ()
