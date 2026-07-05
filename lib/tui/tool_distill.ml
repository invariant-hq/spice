(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* ── Mapping host facts to the generic tool block ────────────────────────── *)

(* The verb table is derived from the real toolset, matching each tool's name
   exactly as the host registers it: the executable tools assembled by
   [Spice_tools.default]/[web]/[Skills.tools] under [Toolset.make]
   (lib/host/toolset.ml) and the host tools enumerated by
   [Spice_protocol.Call.Kind] (lib/protocol/call.ml). Re-audit this table
   whenever a tool is added, renamed, or removed. A name with no 02-tools verb
   falls to [Other], which [Tool_block.label] renders capitalized. There is no
   listing tool in the current toolset, so nothing maps to [Tool_block.List]. *)
let verb_of_name name =
  match name with
  | "read_file" -> Tool_block.Read
  | "search_text" | "glob" | "ocaml_search_expressions" -> Tool_block.Search
  | "edit_file" | "apply_patch" | "ocaml_ast_edit" | "edit_lines"
  | "ocaml_rename" | "ocaml_replace_expressions" ->
      Tool_block.Update
  | "write_file" -> Tool_block.Create
  | "shell" -> Tool_block.Shell
  | "ocaml_eval" -> Tool_block.Eval
  | "web_fetch" -> Tool_block.Fetch
  | "web_search" -> Tool_block.Web_search
  | "spawn_subagent" -> Tool_block.Task
  | "todo_write" -> Tool_block.Todo
  | "ocaml_dune_describe" -> Tool_block.Dune
  | "ocaml_dune_diagnostics" -> Tool_block.Diagnostics
  | "ocaml_docs" -> Tool_block.Outline
  | "ocaml_type_at" -> Tool_block.Type
  | "ocaml_find_definitions" -> Tool_block.Definition
  | "ocaml_find_references" -> Tool_block.References
  | "skill" -> Tool_block.Skill
  | "propose_plan" -> Tool_block.Plan
  | "update_goal" -> Tool_block.Goal
  | "message_subagent" | "message_parent" -> Tool_block.Message
  | "cancel_subagent" -> Tool_block.Cancel
  | "wait_subagents" -> Tool_block.Wait
  | "ask_user" -> Tool_block.Question
  | _ -> Tool_block.Other name

(* Best-effort primary argument: the first present string field among a small
   priority of common input keys. The generic block shows nothing when none
   matches; the full per-tool renderers name arguments precisely later. *)
let json_string = function Jsont.String (s, _) -> Some s | _ -> None

let json_member key = function
  | Jsont.Object (mems, _) ->
      List.find_map
        (fun ((k, _), v) -> if String.equal k key then Some v else None)
        mems
  | _ -> None

let primary_arg json =
  let keys =
    [ "path"; "file_path"; "file"; "command"; "query"; "pattern"; "url"; "name" ]
  in
  match
    List.find_map (fun k -> Option.bind (json_member k json) json_string) keys
  with
  | Some s -> s
  | None -> ""

(* [path:line] and [path:line:col] argument shapes for the OCaml navigation
   tools (02-tools.md §OCaml tools): the header names WHERE the query ran so the
   summary is free to carry the answer (the type, the resolved location, the
   counts). Positions come off the tool's own typed input, never the generic
   [primary_arg] keys. *)
let loc_arg ~path ~line = Printf.sprintf "%s:%d" path line
let loc_col_arg ~path ~line ~col = Printf.sprintf "%s:%d:%d" path line col

let first_input_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

let run_label id = Spice_session.Id.to_string id

(* A subagent spawn is the spec's [Task(@name — description)]: its primary
   argument is built from the [spawn_subagent] input's [role] and [task] fields
   (the schema in lib/protocol/subagent.ml), not the generic [primary_arg] keys,
   which that schema shares none of. Every other tool uses [primary_arg]. *)
let argument_of_call call =
  let input = Spice_llm.Tool.Call.input call in
  match Spice_llm.Tool.Call.name call with
  | "spawn_subagent" -> (
      let field k = Option.bind (json_member k input) json_string in
      match (field "role", field "task") with
      | Some role, Some task -> Printf.sprintf "@%s — %s" role task
      | Some role, None -> "@" ^ role
      | None, Some task -> task
      | None, None -> "")
  (* ask_user's argument is the question itself (02-tools.md §Host questions),
     decoded from the structured request rather than the generic keys. *)
  | "ask_user" -> (
      match Spice_protocol.Question.decode call with
      | Ok request -> Spice_protocol.Question.Request.question request
      | Error _ -> "")
  (* ocaml_type_at: the queried position — the type itself is the result. *)
  | "ocaml_type_at" -> (
      match Spice_tools.Ocaml_type_at.Input.decode input with
      | Ok q ->
          loc_arg
            ~path:(Spice_tools.Ocaml_type_at.Input.path q)
            ~line:
              (Spice_ocaml.Position.line
                 (Spice_tools.Ocaml_type_at.Input.position q))
      | Error _ -> primary_arg input)
  (* ocaml_find_definitions: the identifier when the model named one, else the
     cursor position it resolved from. *)
  | "ocaml_find_definitions" -> (
      match Spice_tools.Ocaml_find_definitions.Input.decode input with
      | Ok q -> (
          match Spice_tools.Ocaml_find_definitions.Input.identifier q with
          | Some id -> id
          | None ->
              loc_col_arg
                ~path:(Spice_tools.Ocaml_find_definitions.Input.path q)
                ~line:(Spice_tools.Ocaml_find_definitions.Input.line q)
                ~col:(Spice_tools.Ocaml_find_definitions.Input.column q))
      | Error _ -> primary_arg input)
  (* ocaml_find_references: the input carries no identifier, only the cursor —
     so the position is the argument (see the upstream gap in [references_block]). *)
  | "ocaml_find_references" -> (
      match Spice_tools.Ocaml_find_references.Input.decode input with
      | Ok q ->
          loc_arg
            ~path:(Spice_tools.Ocaml_find_references.Input.path q)
            ~line:
              (Spice_ocaml.Position.line
                 (Spice_tools.Ocaml_find_references.Input.position q))
      | Error _ -> primary_arg input)
  (* ocaml_eval: the first line of the evaluated phrase, shaped like a Shell
     command header. *)
  | "ocaml_eval" -> (
      match Spice_tools.Ocaml_eval.Input.decode input with
      | Ok q -> first_input_line (Spice_tools.Ocaml_eval.Input.code q)
      | Error _ -> primary_arg input)
  (* The subagent-management tools name the run they act on. The input carries
     the session run id, not the friendly [@role] (the upstream gap in
     [subagent_message_block]); a wait over many runs shows their count. *)
  | "wait_subagents" -> (
      match Spice_protocol.Subagent.Wait.decode call with
      | Ok req -> (
          match Spice_protocol.Subagent.Wait.Request.runs req with
          | [ id ] -> run_label id
          | runs -> Printf.sprintf "%d agents" (List.length runs))
      | Error _ -> "")
  | "cancel_subagent" -> (
      match Spice_protocol.Subagent.Cancel.decode call with
      | Ok req -> run_label (Spice_protocol.Subagent.Cancel.Request.run req)
      | Error _ -> "")
  | "message_subagent" -> (
      match Spice_protocol.Subagent.Message.decode call with
      | Ok req -> run_label (Spice_protocol.Subagent.Message.Request.run req)
      | Error _ -> "")
  | "message_parent" -> "parent"
  | _ -> primary_arg input

let block_of_call ?argument call ~dot ~summary ?(facts = []) ?(disclosable = false)
    ?(detail = Tool_block.Summary) () =
  let argument =
    match argument with Some a -> a | None -> argument_of_call call
  in
  {
    Tool_block.verb = verb_of_name (Spice_llm.Tool.Call.name call);
    argument;
    dot;
    summary;
    facts;
    disclosable;
    detail;
  }

let block_of_claim ?argument claim ~dot ~summary ?(facts = [])
    ?(disclosable = false) ?(detail = Tool_block.Summary) () =
  block_of_call ?argument
    (Spice_session.Tool_claim.Started.call claim)
    ~dot ~summary ~facts ~disclosable ~detail ()

(* A pluralized count clause, e.g. [1 line] / [12 lines] / [3 matches]. *)
let count n ~one ~many = Printf.sprintf "%d %s" n (if n = 1 then one else many)

(* ── Per-tool rendering (02-tools.md) ─────────────────────────────────────── *)

(* Additions and removals across a patch, counted from the hunk lines so the
   summary's [Added N lines] is exact — no scanning of a rendered diff string. *)
let patch_counts patch =
  List.fold_left
    (fun (a, d) (h : Mosaic.Diff.Patch.hunk) ->
      List.fold_left
        (fun (a, d) (l : Mosaic.Diff.Patch.line) ->
          match l.Mosaic.Diff.Patch.tag with
          | Mosaic.Diff.Patch.Added -> (a + 1, d)
          | Mosaic.Diff.Patch.Removed -> (a, d + 1)
          | Mosaic.Diff.Patch.Context -> (a, d))
        (a, d) h.Mosaic.Diff.Patch.lines)
    (0, 0)
    (Mosaic.Diff.Patch.hunks patch)

let files_counts files =
  List.fold_left
    (fun (a, d) (f : Tool_block.diff_file) ->
      let fa, fd = patch_counts f.Tool_block.patch in
      (a + fa, d + fd))
    (0, 0) files

let update_summary ~additions ~deletions =
  let noun n = if n = 1 then "line" else "lines" in
  match (additions, deletions) with
  | 0, 0 -> "unchanged"
  | a, 0 -> Printf.sprintf "Added %d %s" a (noun a)
  | 0, d -> Printf.sprintf "Removed %d %s" d (noun d)
  | a, d ->
      Printf.sprintf "Added %d %s, removed %d %s" a (noun a) d (noun d)

let observed_text o = Option.value ~default:"" (Spice_edit.Observed.text o)

(* Every mutating tool — edit_file, edit_lines, ocaml_ast_edit, apply_patch,
   write_file — collapses to one [Receipt] of before/after images (plus, for
   apply_patch, a per-entry unified diff string). Each change becomes a
   line-level patch: the tool's own diff when present (apply_patch), else a Myers
   diff of the before/after contents. Precomputed once here so a settled block
   re-renders on replay without re-diffing. *)
let diff_files_of_receipt receipt =
  List.filter_map
    (fun (c : Spice_tools.Receipt.change) ->
      let label = Spice_workspace.Path.display c.Spice_tools.Receipt.path in
      let patch =
        match c.Spice_tools.Receipt.diff with
        | Some diff -> Result.to_option (Mosaic.Diff.Patch.of_unified diff)
        | None ->
            Some
              (Mosaic.Diff.Patch.of_strings
                 ~old:(observed_text c.Spice_tools.Receipt.before)
                 ~new_:(observed_text c.Spice_tools.Receipt.after)
                 ())
      in
      match patch with
      | Some patch when not (Mosaic.Diff.Patch.is_empty patch) ->
          Some { Tool_block.label; patch }
      | _ -> None)
    (Spice_tools.Receipt.changes receipt)

(* Update: the full inline diff, always (02-tools.md §File edits). *)
let update_block call output =
  match Spice_tools.Evidence.mutation output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some receipt -> (
      match diff_files_of_receipt receipt with
      | [] -> block_of_call call ~dot:Tool_block.Ok ~summary:"unchanged" ()
      | files ->
          let additions, deletions = files_counts files in
          let argument =
            match files with
            | [ f ] -> f.Tool_block.label
            | _ -> Printf.sprintf "%d files" (List.length files)
          in
          block_of_call ~argument call ~dot:Tool_block.Ok
            ~summary:(update_summary ~additions ~deletions)
            ~detail:(Tool_block.Diff files) ())

(* Create: [Wrote N lines] then the first four content lines (02-tools.md §File
   edits). The trailing newline's empty final element is dropped so the count is
   the file's line count. *)
let create_block call output =
  match Spice_tools.Write_file.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some out ->
      let contents = Spice_tools.Write_file.Output.contents out in
      let lines = String.split_on_char '\n' contents in
      let lines =
        match List.rev lines with "" :: tl -> List.rev tl | _ -> lines
      in
      block_of_call call ~dot:Tool_block.Ok
        ~summary:(Printf.sprintf "Wrote %s" (count (List.length lines) ~one:"line" ~many:"lines"))
        ~detail:(Tool_block.preview ~take:`First ~cap:4 lines)
        ()

(* Read: summary only, content behind disclosure (02-tools.md §Read). *)
let read_block call output =
  let summary =
    match Spice_tools.Read_file.Output.of_tool_output output with
    | None -> "Read"
    | Some out ->
        let open Spice_tools.Read_file.Output in
        (match out with
        | Read r -> "Read " ^ count r.returned_lines ~one:"line" ~many:"lines"
        | Unchanged _ -> "unchanged"
        | Listing l -> count l.total_entries ~one:"entry" ~many:"entries")
  in
  block_of_call call ~dot:Tool_block.Ok ~summary ~disclosable:true ()

(* Search: [Found N …], the shape read off the result kind, content behind
   disclosure (02-tools.md §Read/Search). glob, search_text, and the structural
   ocaml_search_expressions share the verb, each with its own count shape. *)
let search_block call name output =
  let summary =
    if String.equal name "glob" then
      match Spice_tools.Glob.Output.of_tool_output output with
      | None -> "Search"
      | Some o ->
          "Found "
          ^ count (Spice_tools.Glob.Output.total_files o) ~one:"file" ~many:"files"
    else if String.equal name "ocaml_search_expressions" then
      match Spice_tools.Ocaml_search_expressions.Output.of_tool_output output with
      | None -> "Search"
      | Some o ->
          let n = Spice_tools.Ocaml_search_expressions.Output.total_results o in
          if n = 0 then "no matches"
          else
            let files =
              List.sort_uniq String.compare
                (List.map
                   (fun (f : Spice_tools.Ocaml_search_expressions.Output.finding) ->
                     Spice_workspace.Path.display
                       (Spice_ocaml.Location.path
                          f.Spice_tools.Ocaml_search_expressions.Output.location))
                   (Spice_tools.Ocaml_search_expressions.Output.findings o))
            in
            Printf.sprintf "Found %s across %s"
              (count n ~one:"match" ~many:"matches")
              (count (List.length files) ~one:"file" ~many:"files")
    else
      match Spice_tools.Search_text.Output.of_tool_output output with
      | None -> "Search"
      | Some o ->
          let open Spice_tools.Search_text.Output in
          let n = returned_results o in
          (match result o with
          | Files _ -> "Found " ^ count n ~one:"file" ~many:"files"
          | Matches spans ->
              Printf.sprintf "Found %s across %s"
                (count n ~one:"match" ~many:"matches")
                (count (List.length spans) ~one:"file" ~many:"files")
          | Count _ ->
              "Found " ^ count n ~one:"matching line" ~many:"matching lines")
  in
  block_of_call call ~dot:Tool_block.Ok ~summary ~disclosable:true ()

(* Shell: a nonzero exit is a COMPLETED result whose OUTPUT status carries the
   code — the red [exited N] form comes from [Shell.Output.status], never the
   tool's own [Failed] (which means the command could not run at all). Success is
   the quiet [done · Ns]; failure auto-shows the last five output lines
   (02-tools.md §Shell). *)
let stream_text = function
  | Spice_tools.Shell.Output.Complete s -> s
  | Spice_tools.Shell.Output.Truncated { head; tail; _ } -> head ^ "\n" ^ tail

let shell_block call output =
  match Spice_tools.Shell.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let secs =
        Printf.sprintf "%ds" (Spice_tools.Shell.Output.duration_ms o / 1000)
      in
      let failure verb =
        let combined =
          let out = stream_text (Spice_tools.Shell.Output.stdout o) in
          let err = stream_text (Spice_tools.Shell.Output.stderr o) in
          if String.trim err = "" then out
          else if String.trim out = "" then err
          else out ^ "\n" ^ err
        in
        let lines =
          List.filter (fun l -> l <> "") (String.split_on_char '\n' combined)
        in
        block_of_call call ~dot:Tool_block.Failed ~summary:verb ~facts:[ secs ]
          ~detail:(Tool_block.preview ~take:`Last ~cap:5 lines)
          ()
      in
      let open Spice_tools.Shell.Output in
      (match Spice_tools.Shell.Output.status o with
      | Exited 0 ->
          block_of_call call ~dot:Tool_block.Ok ~summary:"done" ~facts:[ secs ]
            ~disclosable:true ()
      | Exited n -> failure (Printf.sprintf "exited %d" n)
      | Signaled s -> failure (Printf.sprintf "signaled %d" s)
      | Timed_out _ -> failure "timed out"
      | Cancelled ->
          block_of_call call ~dot:Tool_block.Warned ~summary:"cancelled"
            ~facts:[ secs ] ()
      | Failed_to_start m -> failure m)

(* ── OCaml tools (02-tools.md §OCaml tools) ───────────────────────────────── *)

(* A [N noun] clause, dropped entirely when the count is zero, so the summary
   lists only the kinds actually present. *)
let clause n ~one ~many = if n = 0 then None else Some (count n ~one ~many)

let first_line s =
  match String.index_opt s '\n' with Some i -> String.sub s 0 i | None -> s

let joined clauses =
  match List.filter_map Fun.id clauses with
  | [] -> "empty"
  | parts -> String.concat " · " parts

(* Outline (ocaml_docs): the declaration counts by kind (02-tools.md §OCaml
   tools). [Module_type] folds into modules; classes fold into types. *)
let outline_block call output =
  match Spice_tools.Ocaml_docs.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let items = Spice_tools.Ocaml_docs.Output.items o in
      let open Spice_tools.Ocaml_docs.Item in
      let n k = List.length (List.filter (fun it -> it.kind = k) items) in
      let values = n Value + n Exception in
      let types = n Type + n Class_type in
      let modules = n Module + n Module_type + n Class in
      let summary =
        joined
          [
            clause values ~one:"value" ~many:"values";
            clause types ~one:"type" ~many:"types";
            clause modules ~one:"module" ~many:"modules";
          ]
      in
      block_of_call call ~dot:Tool_block.Ok ~summary ~disclosable:true ()

(* Dune (ocaml_dune_describe): the project shape (02-tools.md §OCaml tools). *)
let dune_block call output =
  match Spice_tools.Ocaml_dune_describe.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let summary =
        joined
          [
            clause
              (Spice_tools.Ocaml_dune_describe.Output.component_count o)
              ~one:"component" ~many:"components";
            clause
              (Spice_tools.Ocaml_dune_describe.Output.test_count o)
              ~one:"test" ~many:"tests";
          ]
      in
      block_of_call call ~dot:Tool_block.Ok ~summary ~disclosable:true ()

(* Diagnostics (ocaml_dune_diagnostics): [clean] when the Dune diagnostic set is
   empty, else [N errors · M warnings] with a warning-only set warning-dotted and
   the first three diagnostics as [path:line:col  message] rows (02-tools.md
   §OCaml tools). REPORTED gap: the rows render muted rather than severity-colored
   — the Preview detail is monochrome; a severity-colored diagnostic detail is a
   follow-up (and the Dune RPC these tools need is unavailable in the pty harness,
   so this path is unverified). *)
let diagnostics_block call output =
  match Spice_tools.Ocaml_dune_diagnostics.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let diags =
        List.map snd (Spice_tools.Ocaml_dune_diagnostics.Output.diagnostics o)
      in
      if diags = [] then block_of_call call ~dot:Tool_block.Ok ~summary:"clean" ()
      else
        let is sev d = Spice_ocaml.Diagnostic.severity d = sev in
        let errors =
          List.length (List.filter (is Spice_ocaml.Diagnostic.Severity.Error) diags)
        in
        let warnings =
          List.length
            (List.filter (is Spice_ocaml.Diagnostic.Severity.Warning) diags)
        in
        let summary =
          joined
            [
              clause errors ~one:"error" ~many:"errors";
              clause warnings ~one:"warning" ~many:"warnings";
            ]
        in
        let row d =
          let loc =
            match Spice_ocaml.Diagnostic.location d with
            | None -> ""
            | Some l ->
                let p = Spice_ocaml.Location.start l in
                Printf.sprintf "%s:%d:%d  "
                  (Spice_workspace.Path.display (Spice_ocaml.Location.path l))
                  (Spice_ocaml.Position.line p)
                  (Spice_ocaml.Position.column p)
          in
          loc ^ first_line (Spice_ocaml.Diagnostic.message d)
        in
        let dot =
          if errors = 0 then Tool_block.Warned else Tool_block.Failed
        in
        block_of_call call ~dot ~summary
          ~detail:(Tool_block.preview ~take:`First ~cap:3 (List.map row diags))
          ()

(* Type (ocaml_type_at): the result IS the type (02-tools.md §OCaml tools). The
   innermost enclosing's type expression is the summary; a Merlin-truncated or
   multi-line type shows its first line, the remainder behind [▸] (the same
   summary-only + disclosure shape as Read). *)
let type_at_block call output =
  match Spice_tools.Ocaml_type_at.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let frame = Spice_tools.Ocaml_type_at.Output.innermost o in
      let ty = Spice_tools.Ocaml_type_at.Frame.type_string frame in
      let truncated = Spice_tools.Ocaml_type_at.Frame.truncated frame in
      let multiline = String.contains ty '\n' in
      block_of_call call ~dot:Tool_block.Ok ~summary:(first_line ty)
        ~disclosable:(multiline || truncated) ()

(* A resolved definition target as a [path:line] location. *)
let target_location target =
  let open Spice_tools.Ocaml_find_definitions.Definition.Target in
  match target with
  | Workspace loc ->
      loc_arg
        ~path:(Spice_workspace.Path.display (Spice_ocaml.Location.path loc))
        ~line:(Spice_ocaml.Position.line (Spice_ocaml.Location.start loc))
  | External { path; position } ->
      loc_arg ~path ~line:(Spice_ocaml.Position.line position)

(* Definition (ocaml_find_definitions): the resolved location is the result
   (02-tools.md §OCaml tools). A completed call carries the target; the
   Merlin backend returns at most one, so extra targets are only a count fact.
   A lookup miss arrives as a [`Not_found] tool failure, warning-dotted by
   [of_tool_finished], not routed here. *)
let definition_block call output =
  match Spice_tools.Ocaml_find_definitions.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o -> (
      match Spice_tools.Ocaml_find_definitions.Output.definitions o with
      | [] -> block_of_call call ~dot:Tool_block.Warned ~summary:"no definition" ()
      | defs ->
          let def = List.hd defs in
          let summary =
            target_location
              (Spice_tools.Ocaml_find_definitions.Definition.target def)
          in
          let facts =
            match defs with
            | _ :: _ :: _ ->
                [ count (List.length defs) ~one:"definition" ~many:"definitions" ]
            | _ -> []
          in
          block_of_call call ~dot:Tool_block.Ok ~summary ~facts ())

(* References (ocaml_find_references): the occurrence counts are the result, the
   first locations auto-shown beneath as muted [path:line:col] rows like the
   diagnostics detail (02-tools.md §OCaml tools). UPSTREAM GAP: [total_count] is
   the whole result set but the file fact counts only the returned page, so a
   paged result may under-report its file spread. *)
let references_block call output =
  match Spice_tools.Ocaml_find_references.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let refs = Spice_tools.Ocaml_find_references.Output.references o in
      let total = Spice_tools.Ocaml_find_references.Output.total_count o in
      let loc_of r =
        let loc = Spice_tools.Ocaml_find_references.Reference.location r in
        let start = Spice_ocaml.Location.start loc in
        loc_col_arg
          ~path:(Spice_workspace.Path.display (Spice_ocaml.Location.path loc))
          ~line:(Spice_ocaml.Position.line start)
          ~col:(Spice_ocaml.Position.column start)
      in
      let files =
        List.sort_uniq String.compare
          (List.map
             (fun r ->
               Spice_workspace.Path.display
                 (Spice_ocaml.Location.path
                    (Spice_tools.Ocaml_find_references.Reference.location r)))
             refs)
      in
      block_of_call call ~dot:Tool_block.Ok
        ~summary:(count total ~one:"reference" ~many:"references")
        ~facts:[ count (List.length files) ~one:"file" ~many:"files" ]
        ~detail:(Tool_block.preview ~take:`First ~cap:3 (List.map loc_of refs))
        ()

(* Eval (ocaml_eval): a toplevel run, shaped exactly like Shell (02-tools.md
   §Shell) — a zero exit is the quiet [done · Ns], a nonzero exit humanizes to
   [exited N] with the last five output lines auto-shown. The status lives on
   the OUTPUT, not the tool result, so the caller routes here before the tool
   status match, as it does for Shell. *)
let eval_stream_text = function
  | Spice_tools.Ocaml_eval.Output.Complete s -> s
  | Spice_tools.Ocaml_eval.Output.Truncated { head; tail; _ } ->
      head ^ "\n" ^ tail

let eval_block call output =
  match Spice_tools.Ocaml_eval.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let secs =
        Printf.sprintf "%ds" (Spice_tools.Ocaml_eval.Output.duration_ms o / 1000)
      in
      let failure verb =
        let combined =
          let out = eval_stream_text (Spice_tools.Ocaml_eval.Output.stdout o) in
          let err = eval_stream_text (Spice_tools.Ocaml_eval.Output.stderr o) in
          if String.trim err = "" then out
          else if String.trim out = "" then err
          else out ^ "\n" ^ err
        in
        let lines =
          List.filter (fun l -> l <> "") (String.split_on_char '\n' combined)
        in
        block_of_call call ~dot:Tool_block.Failed ~summary:verb ~facts:[ secs ]
          ~detail:(Tool_block.preview ~take:`Last ~cap:5 lines)
          ()
      in
      let open Spice_tools.Ocaml_eval.Output in
      (match Spice_tools.Ocaml_eval.Output.status o with
      | Exited 0 ->
          block_of_call call ~dot:Tool_block.Ok ~summary:"done" ~facts:[ secs ]
            ~disclosable:true ()
      | Exited n -> failure (Printf.sprintf "exited %d" n)
      | Signaled s -> failure (Printf.sprintf "signaled %d" s)
      | Timed_out _ -> failure "timed out"
      | Cancelled ->
          block_of_call call ~dot:Tool_block.Warned ~summary:"cancelled"
            ~facts:[ secs ] ()
      | Failed_to_start m -> failure m)

(* Humanized byte count for the web fetch summary: GB/MB/KB with one decimal,
   plain bytes below a kilobyte (the [bytes_text] shape, on a plain [int]). *)
let human_bytes_int n =
  let v = float_of_int n in
  if v >= 1_000_000_000. then Printf.sprintf "%.1f GB" (v /. 1_000_000_000.)
  else if v >= 1_000_000. then Printf.sprintf "%.1f MB" (v /. 1_000_000.)
  else if v >= 1_000. then Printf.sprintf "%.1f KB" (v /. 1_000.)
  else Printf.sprintf "%d B" n

(* Fetch (web_fetch): [Received <size> (<code>)] on a 2xx body (02-tools.md
   §Web tools); a redirect or non-2xx is a warning-dotted status line, never
   red — the model asked for a URL and got an answer, just not a body. *)
let fetch_block call output =
  match Spice_tools.Web_fetch.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o -> (
      let open Spice_tools.Web_fetch.Output in
      match status o with
      | Fetched { code; _ } ->
          block_of_call call ~dot:Tool_block.Ok
            ~summary:
              (Printf.sprintf "Received %s (%d)"
                 (human_bytes_int (bytes_read o))
                 code)
            ~disclosable:true ()
      | Redirected { code; to_url; _ } ->
          block_of_call call ~dot:Tool_block.Warned
            ~summary:(Printf.sprintf "redirected (%d)" code)
            ~facts:[ Spice_tools.Web.Url.host to_url ]
            ()
      | Http_error { code; code_text; _ } ->
          block_of_call call ~dot:Tool_block.Warned
            ~summary:(Printf.sprintf "HTTP %d %s" code code_text)
            ())

(* Web Search (web_search): [N results · <duration>] (02-tools.md §Web tools),
   the result titles and URLs behind disclosure. *)
let web_search_block call output =
  match Spice_tools.Web_search.Output.of_tool_output output with
  | None -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()
  | Some o ->
      let n = List.length (Spice_tools.Web_search.Output.results o) in
      let secs =
        Printf.sprintf "%.1fs"
          (float_of_int (Spice_tools.Web_search.Output.duration_ms o) /. 1000.)
      in
      block_of_call call ~dot:Tool_block.Ok
        ~summary:(count n ~one:"result" ~many:"results")
        ~facts:[ secs ] ~disclosable:true ()

(* Skill (skill): a skill's guidance loaded into context, or a named resource
   file read from it (02-tools.md §OCaml tools is file work; the skill row is a
   plain load). The guidance text itself is the tool result shown to the model;
   the transcript records only the load, its body behind disclosure. *)
let skill_block call =
  let input = Spice_llm.Tool.Call.input call in
  let summary =
    match Option.bind (json_member "resource" input) json_string with
    | Some r when String.trim r <> "" && r <> "/" -> "read " ^ r
    | _ -> "loaded"
  in
  block_of_call call ~dot:Tool_block.Ok ~summary ~disclosable:true ()

(* The todo board's item projection and the block it renders as, built from the
   [todo_write] call's own input (each write is a full replacement list). Shared
   by the [Tool_finished]/[Host_call] settle and the live [t.todo] mirror. *)
let todo_status_of = function
  | Spice_protocol.Todo.Status.Completed | Spice_protocol.Todo.Status.Cancelled
    ->
      Tool_block.Done
  | Spice_protocol.Todo.Status.In_progress -> Tool_block.Active
  | Spice_protocol.Todo.Status.Pending -> Tool_block.Pending

let todo_block todo =
  let items =
    List.map
      (fun it ->
        {
          Tool_block.status =
            todo_status_of (Spice_protocol.Todo.Item.status it);
          content = Spice_protocol.Todo.Item.content it;
        })
      (Spice_protocol.Todo.items todo)
  in
  let count st =
    List.length (List.filter (fun i -> i.Tool_block.status = st) items)
  in
  let argument =
    Printf.sprintf "%d tasks · %d done · %d running" (List.length items)
      (count Tool_block.Done) (count Tool_block.Active)
  in
  {
    Tool_block.verb = Tool_block.Todo;
    argument;
    dot = Tool_block.Ok;
    summary = "";
    facts = [];
    disclosable = false;
    detail = Tool_block.Todos items;
  }

(* The [todo_write] board, decoded from the call input; a malformed list falls
   back to the generic done row. *)
let todo_finished_block call =
  match Spice_protocol.Todo.decode call with
  | Ok todos -> todo_block todos
  | Error _ -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()

(* ask_user (Question) records the answer, never [⏺ Ask_user ⎿ done] (02-tools.md
   §Host questions): the question is the header argument (via [argument_of_call])
   and the answer — carried in the host-call result text — quotes in the summary.
   A cancelled wait settles warning-dotted [interrupted]. *)
let question_block call result =
  if Spice_llm.Tool.Result.is_error result then
    block_of_call call ~dot:Tool_block.Warned ~summary:"interrupted" ()
  else
    let answer =
      String.trim (String.concat " " (Spice_llm.Tool.Result.texts result))
    in
    let summary =
      if answer = "" then "answered"
      else Printf.sprintf "answered · \"%s\"" (first_line answer)
    in
    block_of_call call ~dot:Tool_block.Ok ~summary ()

(* ── Subagent management (02-tools.md §Subagent management) ────────────────── *)

(* The host builds these results as free text (lib/host/handler.ml
   [result_text]), so the summary carries the ACT (delivered / cancelled / done)
   and, on failure, the host's own first error line — never a parse of prose.
   UPSTREAM GAP: the results carry no structured timing or settled-agent
   outcome, and the inputs name the session run id, not the friendly [@role]. *)
let host_error_summary result ~fallback =
  let t = String.trim (String.concat " " (Spice_llm.Tool.Result.texts result)) in
  if t = "" then fallback else first_line t

(* Message (message_subagent / message_parent): the delivered message quotes in
   the summary, its first line truncated to the header budget by wrapping. *)
let message_quote call =
  let quote_of m =
    let m = String.trim m in
    if m = "" then None else Some (first_line m)
  in
  match Spice_protocol.Subagent.Message.decode call with
  | Ok req -> quote_of (Spice_protocol.Subagent.Message.Request.message req)
  | Error _ -> (
      match Spice_protocol.Subagent.Message_parent.decode call with
      | Ok req ->
          quote_of (Spice_protocol.Subagent.Message_parent.Request.message req)
      | Error _ -> None)

let message_block call result =
  if Spice_llm.Tool.Result.is_error result then
    block_of_call call ~dot:Tool_block.Warned
      ~summary:(host_error_summary result ~fallback:"not delivered")
      ()
  else
    let summary =
      match message_quote call with
      | Some q -> Printf.sprintf "delivered · \"%s\"" q
      | None -> "delivered"
    in
    block_of_call call ~dot:Tool_block.Ok ~summary ()

let cancel_block call result =
  if Spice_llm.Tool.Result.is_error result then
    block_of_call call ~dot:Tool_block.Warned
      ~summary:(host_error_summary result ~fallback:"not cancelled")
      ()
  else block_of_call call ~dot:Tool_block.Ok ~summary:"cancelled" ()

let wait_block call result =
  if Spice_llm.Tool.Result.is_error result then
    block_of_call call ~dot:Tool_block.Warned
      ~summary:(host_error_summary result ~fallback:"wait failed")
      ()
  else
    let facts =
      match Spice_protocol.Subagent.Wait.decode call with
      | Ok req ->
          let n = List.length (Spice_protocol.Subagent.Wait.Request.runs req) in
          if n > 1 then [ count n ~one:"agent" ~many:"agents" ] else []
      | Error _ -> []
    in
    block_of_call call ~dot:Tool_block.Ok ~summary:"done" ~facts ()

let of_tool_finished claim result =
  let call = Spice_session.Tool_claim.Started.call claim in
  let name = Spice_llm.Tool.Call.name call in
  let verb = verb_of_name name in
  let output = Spice_tool.Result.output result in
  (* Shell decides success/failure from its OUTPUT status, not the tool result:
     a nonzero exit is a [Failed] result whose exit code and captured output are
     carried on the attached [Shell.Output] (shell.ml [result_of_output]). Route
     it to [shell_block] before the status match so the [exited N · Ns] form and
     the output tail render instead of the raw [command exited with status N]
     message (02-tools.md §Shell). *)
  (* Shell and Eval both carry their exit status on the OUTPUT, not the tool
     result — route them before the status match so a nonzero exit humanizes to
     [exited N · Ns] with its output tail (02-tools.md §Shell). *)
  match (verb, output) with
  | Tool_block.Shell, Some o -> shell_block call o
  | Tool_block.Eval, Some o -> eval_block call o
  | _ -> (
      match Spice_tool.Result.status result with
      | Spice_tool.Result.Failed { kind; message; _ } ->
          (* An OCaml navigation miss ([`Not_found]/[`Stale]) and an unavailable
             Merlin are expected lookup outcomes, not the model's error: they
             settle warning-dotted with the honest message (02-tools.md §OCaml
             tools). Every other failure keeps the red dot. *)
          let dot =
            match (verb, kind) with
            | ( (Tool_block.Type | Tool_block.Definition | Tool_block.References),
                (`Not_found | `Stale | `Unavailable) ) ->
                Tool_block.Warned
            | _ -> Tool_block.Failed
          in
          block_of_call call ~dot ~summary:message ()
      | Spice_tool.Result.Interrupted _ ->
          block_of_call call ~dot:Tool_block.Warned ~summary:"interrupted" ()
      | Spice_tool.Result.Completed -> (
          match (verb, output) with
          | Tool_block.Update, Some o -> update_block call o
          | Tool_block.Create, Some o -> create_block call o
          | Tool_block.Read, Some o -> read_block call o
          | Tool_block.Search, Some o -> search_block call name o
          | Tool_block.Outline, Some o -> outline_block call o
          | Tool_block.Dune, Some o -> dune_block call o
          | Tool_block.Diagnostics, Some o -> diagnostics_block call o
          | Tool_block.Type, Some o -> type_at_block call o
          | Tool_block.Definition, Some o -> definition_block call o
          | Tool_block.References, Some o -> references_block call o
          | Tool_block.Fetch, Some o -> fetch_block call o
          | Tool_block.Web_search, Some o -> web_search_block call o
          | Tool_block.Skill, _ -> skill_block call
          (* [todo_write] settles as the board at its call site whether the host
             routes it through [Tool_finished] (executable) or [Host_call]
             (host-handled); the board is decoded from the call input. *)
          | Tool_block.Todo, _ -> todo_finished_block call
          | _ -> block_of_call call ~dot:Tool_block.Ok ~summary:"done" ()))


(* ── Settling a host-tool call to its document block ──────────────────────── *)

(* The block for a settled host-handled call, dispatched on the tool name: the
   board, the answered question, the subagent-management acts, plan/goal, and the
   generic done/failed row. The executable tools settle through
   [of_tool_finished]; permission and turn-end stubs through [denied] /
   [interrupted_call] / [interrupted_claim]. *)
let of_host_call call result =
  match Spice_llm.Tool.Call.name call with
  | "todo_write" -> todo_finished_block call
  | "ask_user" -> question_block call result
  | "message_subagent" | "message_parent" -> message_block call result
  | "cancel_subagent" -> cancel_block call result
  | "wait_subagents" -> wait_block call result
  | name ->
      let dot =
        if Spice_llm.Tool.Result.is_error result then Tool_block.Failed
        else Tool_block.Ok
      in
      let summary =
        match name with
        | "propose_plan" -> "proposed"
        | "update_goal" -> "updated"
        | _ -> "done"
      in
      block_of_call call ~dot ~summary ()

let denied call = block_of_call call ~dot:Tool_block.Warned ~summary:"denied" ()

let interrupted_call call =
  block_of_call call ~dot:Tool_block.Warned ~summary:"interrupted" ()

let interrupted_claim claim =
  block_of_claim claim ~dot:Tool_block.Warned ~summary:"interrupted" ()
