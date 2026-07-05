(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Anchor = Anchor
module Anchor_tracker = Anchor_tracker
module Receipt = Receipt
module Read_file = Read_file
module Write_file = Write_file
module Search_text = Search_text
module Glob = Glob
module Edit_file = Edit_file
module Edit_lines = Edit_lines
module Apply_patch = Apply_patch
module Web = Web
module Web_fetch = Web_fetch
module Web_search = Web_search
module Ocaml_merlin = Ocaml_merlin
module Ocaml_ast_edit = Ocaml_ast_edit
module Ocaml_eval = Ocaml_eval
module Ocaml_dune_describe = Ocaml_dune_describe
module Ocaml_dune_diagnostics = Ocaml_dune_diagnostics
module Ocaml_docs = Ocaml_docs
module Ocaml_find_definitions = Ocaml_find_definitions
module Ocaml_find_references = Ocaml_find_references
module Ocaml_rename = Ocaml_rename
module Ocaml_replace_expressions = Ocaml_replace_expressions
module Ocaml_search_expressions = Ocaml_search_expressions
module Ocaml_type_at = Ocaml_type_at
module Shell = Shell

module Evidence = struct
  type t =
    | Read_file of Read_file.Output.t
    | Search_text of Search_text.Output.t
    | Glob of Glob.Output.t
    | Mutation of { tool : string; receipt : Receipt.t }
    | Web_fetch of Web_fetch.Output.t
    | Web_search of Web_search.Output.t
    | Ocaml_eval of Ocaml_eval.Output.t
    | Ocaml_dune_describe of Ocaml_dune_describe.Output.t
    | Ocaml_dune_diagnostics of Ocaml_dune_diagnostics.Output.t
    | Ocaml_docs of Ocaml_docs.Output.t
    | Ocaml_find_definitions of Ocaml_find_definitions.Output.t
    | Ocaml_find_references of Ocaml_find_references.Output.t
    | Ocaml_search_expressions of Ocaml_search_expressions.Output.t
    | Ocaml_type_at of Ocaml_type_at.Output.t
    | Shell of Shell.Output.t

  let of_output output =
    let candidates =
      [
        (fun () ->
          Option.map
            (fun value -> Read_file value)
            (Read_file.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Write_file.name;
                  receipt = Write_file.Output.receipt value;
                })
            (Write_file.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Search_text value)
            (Search_text.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Glob value)
            (Glob.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Edit_file.name;
                  receipt = Edit_file.Output.receipt value;
                })
            (Edit_file.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Edit_lines.name;
                  receipt = Edit_lines.Output.receipt value;
                })
            (Edit_lines.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Apply_patch.name;
                  receipt = Apply_patch.Output.receipt value;
                })
            (Apply_patch.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Web_fetch value)
            (Web_fetch.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Web_search value)
            (Web_search.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Ocaml_ast_edit.name;
                  receipt = Ocaml_ast_edit.Output.receipt value;
                })
            (Ocaml_ast_edit.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_eval value)
            (Ocaml_eval.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_dune_describe value)
            (Ocaml_dune_describe.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_dune_diagnostics value)
            (Ocaml_dune_diagnostics.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_docs value)
            (Ocaml_docs.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_find_definitions value)
            (Ocaml_find_definitions.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_find_references value)
            (Ocaml_find_references.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_search_expressions value)
            (Ocaml_search_expressions.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Ocaml_type_at value)
            (Ocaml_type_at.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Ocaml_rename.name;
                  receipt = Ocaml_rename.Output.receipt value;
                })
            (Ocaml_rename.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value ->
              Mutation
                {
                  tool = Ocaml_replace_expressions.name;
                  receipt = Ocaml_replace_expressions.Output.receipt value;
                })
            (Ocaml_replace_expressions.Output.of_tool_output output));
        (fun () ->
          Option.map
            (fun value -> Shell value)
            (Shell.Output.of_tool_output output));
      ]
    in
    List.find_map (fun candidate -> candidate ()) candidates

  let mutation_of_t = function
    | Mutation { receipt; _ } -> Some receipt
    | Read_file _ | Search_text _ | Glob _ | Web_fetch _ | Web_search _
    | Ocaml_eval _ | Ocaml_dune_describe _ | Ocaml_dune_diagnostics _
    | Ocaml_docs _ | Ocaml_find_definitions _ | Ocaml_find_references _
    | Ocaml_search_expressions _ | Ocaml_type_at _ | Shell _ ->
        None

  let mutation output = Option.bind (of_output output) mutation_of_t
end

let mutating_tool name =
  List.exists (String.equal name)
    [
      "write_file";
      "edit_file";
      "edit_lines";
      "apply_patch";
      "ocaml_ast_edit";
      "ocaml_rename";
      "ocaml_replace_expressions";
      "shell";
    ]

let web ~sw ~mono_clock ~net ~fetch_https ~http ~policy () =
  if not (Web.Policy.enabled policy) then []
  else
    let fetch =
      [ Web_fetch.tool ~sw ~mono_clock ~net ~https:fetch_https ~policy () ]
    in
    match Web.Policy.search_backend policy with
    | Web.Policy.Disabled -> fetch
    | Web.Policy.Brave _ ->
        fetch @ [ Web_search.tool ~sw ~mono_clock ~http ~policy () ]

module Editor = struct
  type t = Apply_patch | String_replace

  let to_string = function
    | Apply_patch -> "apply-patch"
    | String_replace -> "string-replace"

  let of_string = function
    | "apply-patch" -> Some Apply_patch
    | "string-replace" -> Some String_replace
    | _ -> None

  let equal a b =
    match (a, b) with
    | Apply_patch, Apply_patch | String_replace, String_replace -> true
    | (Apply_patch | String_replace), _ -> false
end

let read_render anchors =
  Option.map
    (fun (resolver : Anchor.Resolver.t) ->
      Read_file.Output.anchored ~source:resolver.Anchor.Resolver.source ())
    anchors

let search_render anchors =
  Option.map
    (fun (resolver : Anchor.Resolver.t) ->
      Search_text.Output.anchored ~source:resolver.Anchor.Resolver.source ())
    anchors

let files ?anchors ~fs ~workspace () =
  let read_render = read_render anchors in
  [ Read_file.tool ~fs ~workspace ?render:read_render () ]

let search ?anchors ~fs ~workspace () =
  let search_render = search_render anchors in
  [
    Search_text.tool ~fs ~workspace ?render:search_render ();
    Glob.tool ~fs ~workspace ();
  ]

let edits ?(mutating = true) ?anchors ~editor ~fs ~workspace () =
  if not mutating then []
  else
    (* The editor family owns the whole general mutation surface, so a
       mismatched write_file/apply_patch pairing is unrepresentable.
       ocaml_ast_edit is in neither family and always follows; edit_lines is
       anchors-gated and orthogonal. *)
    let editor_tools =
      match editor with
      | Editor.String_replace ->
          [
            Write_file.tool ~fs ~workspace (); Edit_file.tool ~fs ~workspace ();
          ]
      | Editor.Apply_patch -> [ Apply_patch.tool ~fs ~workspace () ]
    in
    editor_tools
    @ [ Ocaml_ast_edit.tool ~fs ~workspace () ]
    @
    match anchors with
    | None -> []
    | Some resolver -> [ Edit_lines.tool ~fs ~workspace ~resolver () ]

let ocaml ?(mutating = true) ?project_source ?merlin_program ?watch ~fs
    ~process_mgr ~clock ~cwd ~dune ~workspace () =
  List.concat
    [
      (if mutating then
         [
           Ocaml_eval.tool ~fs ~workspace
             ~config:(Ocaml_eval.Config.make ())
             ?watch ();
           Ocaml_rename.tool ?program:merlin_program ~fs ~workspace ();
           Ocaml_replace_expressions.tool ~fs ~workspace ();
         ]
       else []);
      [
        Ocaml_dune_describe.tool ~process_mgr ~clock ~cwd ~workspace
          ?project_source ();
        Ocaml_dune_diagnostics.tool ~dune ();
        Ocaml_docs.tool ?program:merlin_program ?project_source ~process_mgr
          ~clock ~fs ~cwd ~workspace ();
        Ocaml_find_definitions.tool ?program:merlin_program ~fs ~workspace ();
        Ocaml_find_references.tool ?program:merlin_program ~fs ~workspace ();
        Ocaml_search_expressions.tool ~fs ~workspace ();
        Ocaml_type_at.tool ?program:merlin_program ~fs ~workspace ();
      ];
    ]

let shell ~fs ~workspace ~config () = [ Shell.tool ~fs ~workspace ~config () ]

let default ?(mutating = true) ?project_source ?merlin_program ?watch ?anchors
    ~editor ~fs ~process_mgr ~clock ~cwd ~dune ~workspace ~shell:shell_config ()
    =
  List.concat
    [
      files ?anchors ~fs ~workspace ();
      search ?anchors ~fs ~workspace ();
      edits ~mutating ?anchors ~editor ~fs ~workspace ();
      ocaml ~mutating ?project_source ?merlin_program ?watch ~fs ~process_mgr
        ~clock ~cwd ~dune ~workspace ();
      shell ~fs ~workspace ~config:shell_config ();
    ]
