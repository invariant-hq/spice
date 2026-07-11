(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Docs = Spice_tools.Ocaml_docs
module Dune = Spice_ocaml_dune
module Ocaml = Spice_ocaml
module Tool = Spice_tool
module Workspace = Spice_workspace

let sandbox = Spice_sandbox.seal Spice_sandbox.Spec.Unconfined

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let print_case name = Printf.printf "-- %s --\n" name

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute test path %S: %s" path
        (Spice_path.Error.message error)

let path root rel = Filename.concat root rel

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | stats -> (
      match stats.Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path
          |> Array.iter (fun name ->
              if (not (String.equal name ".")) && not (String.equal name "..")
              then rm_rf (Filename.concat path name));
          Unix.rmdir path
      | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO
      | Unix.S_SOCK ->
          Unix.unlink path)

let mkdir_p dir =
  let rec loop dir =
    if Sys.file_exists dir then ()
    else begin
      loop (Filename.dirname dir);
      Unix.mkdir dir 0o755
    end
  in
  loop dir

let write_disk file contents =
  mkdir_p (Filename.dirname file);
  let oc = open_out_bin file in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc contents;
      flush oc)

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-docs-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let demo_mli =
  "(** Demo library synopsis. *)\n\n\
   val greet : string -> string\n\
   (** [greet name] greets [name]. *)\n\n\
   type color =\n\
  \  | Red\n\
  \  | Green\n\
  \  | Blue\n\
   (** A colour. *)\n\n\
   module Nested : sig\n\
  \  val value : int\n\
  \  (** The answer. *)\n\n\
  \  module Inner : sig\n\
  \    val deep : unit -> unit\n\
  \  end\n\
   end\n"

let impl_only_ml =
  "let counter = ref 0\n\n\
   let bump () = incr counter\n\n\
   type t = { size : int }\n"

let with_fixture f =
  with_temp_dir @@ fun root ->
  write_disk (path root "lib/demo/demo.mli") demo_mli;
  write_disk (path root "lib/demo/impl_only.ml") impl_only_ml;
  write_disk (path root "broken.ml") "let x =\n";
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env ->
  f
    ~process_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env) ~fs:(Eio.Stdenv.fs env)
    ~cwd:(Eio.Stdenv.cwd env) ~workspace

let level_string = function
  | Docs.Output.File_outline -> "file_outline"
  | Docs.Output.Library_overview -> "library_overview"
  | Docs.Output.Module_outline -> "module_outline"
  | Docs.Output.Item_focus -> "item_focus"

let total_string = function
  | Docs.Output.Exact n -> string_of_int n
  | Docs.Output.Unknown -> "unknown"

let status_string = function
  | Docs.Output.Complete -> "complete"
  | Docs.Output.Partial { next } ->
      Printf.sprintf "partial next_query=%s next_offset=%s"
        (Docs.Input.query next)
        (match Docs.Input.offset next with
        | None -> "-"
        | Some offset -> string_of_int offset)

let flat s =
  s |> String.split_on_char '\n' |> List.map String.trim
  |> List.filter (fun s -> not (String.equal s ""))
  |> String.concat " "

let item_line (item : Docs.Item.t) =
  let doc =
    match item.Docs.Item.doc with
    | None -> ""
    | Some doc ->
        Printf.sprintf " doc=%S%s" (flat doc)
          (if item.Docs.Item.doc_truncated then "(truncated)" else "")
  in
  let child_count =
    match item.Docs.Item.child_count with
    | None -> ""
    | Some count -> Printf.sprintf " children=%d" count
  in
  Printf.sprintf "  [%d] %s %s = %S%s%s" item.Docs.Item.depth
    (Docs.Item.kind_to_string item.Docs.Item.kind)
    (String.concat "." item.Docs.Item.path)
    (flat item.Docs.Item.signature)
    child_count doc

let print_output output =
  Printf.printf "provenance: %s\n" (Docs.Output.provenance output);
  Printf.printf "level=%s interface_available=%b library=%s source=%s\n"
    (level_string (Docs.Output.level output))
    (Docs.Output.interface_available output)
    (Option.value ~default:"-" (Docs.Output.library output))
    (Docs.Output.source_path output);
  begin match Docs.Output.synopsis output with
  | None -> ()
  | Some synopsis -> Printf.printf "synopsis: %s\n" (flat synopsis)
  end;
  begin match Docs.Output.modules output with
  | [] -> ()
  | modules -> Printf.printf "modules: %s\n" (String.concat " " modules)
  end;
  begin match Docs.Output.sublibraries output with
  | [] -> ()
  | subs -> Printf.printf "sublibraries: %s\n" (String.concat " " subs)
  end;
  Printf.printf "items=%d/%s offset=%d status=%s\n"
    (List.length (Docs.Output.items output))
    (total_string (Docs.Output.total output))
    (Docs.Output.offset output)
    (status_string (Docs.Output.status output));
  List.iter
    (fun item -> print_endline (item_line item))
    (Docs.Output.items output)

let print_result result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> print_output output
      | None -> print_endline "completed without output")
  | Tool.Result.Failed { kind; message; metadata = _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

(* Force the Merlin fallback to be unavailable so a mid-edit file is reported
   deterministically as a parser failure rather than depending on a system
   ocamlmerlin binary. *)
let no_merlin = [ "spice-no-such-merlin" ]

let run ?(program = no_merlin) ~process_mgr ~clock ~fs ~cwd ~workspace input =
  Docs.run ~sandbox ~program ~process_mgr ~clock ~fs ~cwd ~workspace input
  |> print_result

(* Failure wording comes from the shared FS/edit error mappers; assert only the
   stable failure kind so the golden does not pin exact message text. *)
let run_kind ?(program = no_merlin) ~process_mgr ~clock ~fs ~cwd ~workspace
    input =
  match
    Tool.Result.status
      (Docs.run ~sandbox ~program ~process_mgr ~clock ~fs ~cwd ~workspace input)
  with
  | Tool.Result.Completed -> print_endline "completed"
  | Tool.Result.Failed { kind; _ } ->
      Printf.printf "failed %s\n" (Tool.Result.failure_to_string kind)
  | Tool.Result.Interrupted _ -> print_endline "interrupted"

let%expect_test "path form outlines an interface file" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  run ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "lib/demo/demo.mli");
  [%expect
    {|
    provenance: workspace file lib/demo/demo.mli
    level=file_outline interface_available=true library=- source=lib/demo/demo.mli
    items=3/3 offset=1 status=complete
      [0] value greet = "val greet : string -> string" doc="[greet name] greets [name]."
      [0] type color = "type color = | Red | Green | Blue"
      [0] module Nested = "module Nested : sig ... end" children=2
    |}]

let%expect_test "depth expands nested modules inline" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  run ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make ~depth:1 "lib/demo/demo.mli");
  [%expect
    {|
    provenance: workspace file lib/demo/demo.mli
    level=file_outline interface_available=true library=- source=lib/demo/demo.mli
    items=5/5 offset=1 status=complete
      [0] value greet = "val greet : string -> string" doc="[greet name] greets [name]."
      [0] type color = "type color = | Red | Green | Blue"
      [0] module Nested = "module Nested : sig ... end"
      [1] value Nested.value = "val value : int" doc="The answer."
      [1] module Nested.Inner = "module Inner : sig ... end" children=1
    |}]

let%expect_test "path form outlines an implementation file" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  run ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "lib/demo/impl_only.ml");
  [%expect
    {|
    provenance: workspace file lib/demo/impl_only.ml
    level=file_outline interface_available=false library=- source=lib/demo/impl_only.ml
    items=3/3 offset=1 status=complete
      [0] value counter = "let counter = ref 0"
      [0] value bump = "let bump () = incr counter"
      [0] type t = "type t = { size : int }"
    |}]

let%expect_test "pagination emits a follow-up input" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  run ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make ~limit:1 "lib/demo/demo.mli");
  [%expect
    {|
    provenance: workspace file lib/demo/demo.mli
    level=file_outline interface_available=true library=- source=lib/demo/demo.mli
    items=1/3 offset=1 status=partial next_query=lib/demo/demo.mli next_offset=2
      [0] value greet = "val greet : string -> string" doc="[greet name] greets [name]."
    |}]

let%expect_test "path form failures" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  print_case "missing";
  run_kind ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "lib/demo/missing.mli");
  print_case "directory";
  run_kind ~process_mgr ~clock ~fs ~cwd ~workspace (Docs.Input.make "lib/demo/");
  print_case "outside workspace";
  run_kind ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "../escape.ml");
  print_case "mid-edit unparseable (merlin unavailable)";
  run_kind ~process_mgr ~clock ~fs ~cwd ~workspace (Docs.Input.make "broken.ml");
  [%expect
    {|
    -- missing --
    failed not_found
    -- directory --
    failed invalid_input
    -- outside workspace --
    failed invalid_input
    -- mid-edit unparseable (merlin unavailable) --
    failed invalid_input
    |}]

let%expect_test "input decode" =
  let print_decode label json =
    let result =
      match Docs.Input.decode json with
      | Error _ -> "error"
      | Ok input ->
          Printf.sprintf "ok query=%s scope=%s package=%s depth=%s limit=%s"
            (Docs.Input.query input)
            (match Docs.Input.scope input with
            | Docs.Input.Workspace -> "workspace"
            | Docs.Input.Deps -> "deps"
            | Docs.Input.Any -> "any")
            (Option.value ~default:"-" (Docs.Input.package input))
            (match Docs.Input.depth input with
            | None -> "-"
            | Some depth -> string_of_int depth)
            (match Docs.Input.limit input with
            | None -> "-"
            | Some limit -> string_of_int limit)
    in
    Printf.printf "%s: %s\n" label result
  in
  print_decode "minimal" (json_obj [ ("query", Json.string "Eio.Path") ]);
  print_decode "full"
    (json_obj
       [
         ("query", Json.string "Foo.bar");
         ("scope", Json.string "deps");
         ("package", Json.string "eio.unix");
         ("depth", Json.int 2);
         ("limit", Json.int 5);
       ]);
  print_decode "unknown field"
    (json_obj [ ("query", Json.string "x"); ("mode", Json.string "files") ]);
  print_decode "empty query" (json_obj [ ("query", Json.string "") ]);
  print_decode "bad scope"
    (json_obj [ ("query", Json.string "x"); ("scope", Json.string "switch") ]);
  [%expect
    {|
    minimal: ok query=Eio.Path scope=any package=- depth=- limit=-
    full: ok query=Foo.bar scope=deps package=eio.unix depth=2 limit=5
    unknown field: error
    empty query: error
    bad scope: error
    |}]

let%expect_test "permissions surface" =
  with_fixture @@ fun ~process_mgr:_ ~clock:_ ~fs:_ ~cwd:_ ~workspace ->
  Printf.printf "path form requests: %d\n"
    (List.length
       (Docs.permissions ~sandbox ~workspace
          (Docs.Input.make "lib/demo/demo.mli")));
  Printf.printf "name form requests: %d\n"
    (List.length
       (Docs.permissions ~sandbox ~opam_switch_prefix:"/tmp/switch" ~workspace
          (Docs.Input.make "eio")));
  [%expect {|
    path form requests: 1
    name form requests: 1
    |}]

let%expect_test "erased tool adapter" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  let tool =
    Docs.tool ~sandbox ~program:no_merlin ~process_mgr ~clock ~fs ~cwd
      ~workspace ()
  in
  let call =
    match
      Tool.Call.decode [ tool ] ~name:Docs.name
        ~input:(json_obj [ ("query", Json.string "lib/demo/demo.mli") ])
        ()
    with
    | Ok call -> call
    | Error error ->
        failf "failed to decode adapter call: %a" Tool.Error.pp error
  in
  Printf.printf "permissions: %d\n" (List.length (Tool.Call.permissions call));
  let result = Tool.Call.run call () in
  (match Tool.Result.output result with
  | Some output -> print_string (Tool.Output.text output)
  | None -> failf "adapter returned no output");
  [%expect
    {|
    permissions: 1
    workspace file lib/demo/demo.mli
    level=file_outline source=lib/demo/demo.mli interface_available=true
    items=3/3 offset=1
    - value greet: val greet : string -> string
      doc: [greet name] greets [name].
    - type color: type color = | Red | Green | Blue
    - module Nested: module Nested : sig ... end (2 members)
    |}]

(* ------------------------------------------------------------------ *)
(* Build-lock freshness + multi-token merlin program threading         *)
(* ------------------------------------------------------------------ *)

let freshness_string = function
  | None -> "none"
  | Some Dune.Project_source.Freshness.Fresh -> "fresh"
  | Some (Dune.Project_source.Freshness.Snapshot { drifted; endpoint; _ }) ->
      Printf.sprintf "snapshot drifted=%b endpoint=%s" drifted
        (Option.value ~default:"<none>" endpoint)

let print_freshness_field result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some o ->
          Printf.printf "level=%s describe_freshness=%s\n"
            (level_string (Docs.Output.level o))
            (freshness_string (Docs.Output.describe_freshness o))
      | None -> print_endline "no output")
  | Tool.Result.Failed { kind; message; _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted _ -> print_endline "interrupted"

(* A minimal fake describe: a single local library [demo] whose interface is the
   fixture's lib/demo/demo.mli, so a name-form query resolves without real dune. *)
let demo_project ~workspace =
  let intf =
    match Workspace.resolve_string workspace "lib/demo/demo.mli" with
    | Ok path -> path
    | Error error ->
        failf "resolve demo.mli: %s" (Workspace.Resolve_error.message error)
  in
  let unit =
    Ocaml.Project.Compilation_unit.make ~intf (Ocaml.Module_name.make "Demo")
  in
  let component =
    Ocaml.Project.Component.local_library ~name:"demo" ~units:[ unit ] ()
  in
  Ocaml.Project.make [ component ]

let%expect_test "name form carries fresh describe_freshness via project_source"
    =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  let source =
    Dune.Project_source.create
      ~refresh_status:(fun () -> Dune.Project_source.No_watch)
      ~describe:(fun ~cancelled:_ -> Ok (demo_project ~workspace))
      ~now:(fun () -> 1000.0)
      ()
  in
  Docs.run ~sandbox ~project_source:source ~process_mgr ~clock ~fs ~cwd
    ~workspace
    (Docs.Input.make "demo")
  |> print_freshness_field;
  [%expect {| level=library_overview describe_freshness=fresh |}]

let%expect_test "name form snapshot describe_freshness under a watch" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  let source =
    Dune.Project_source.create
      ~refresh_status:(fun () ->
        Dune.Project_source.Watch_endpoint "dune-rpc:8")
      ~describe:(fun ~cancelled:_ -> Ok (demo_project ~workspace))
      ~now:(fun () -> 1000.0)
      ()
  in
  (match Dune.Project_source.capture source with Ok () -> () | Error _ -> ());
  Docs.run ~sandbox ~project_source:source ~process_mgr ~clock ~fs ~cwd
    ~workspace
    (Docs.Input.make "demo")
  |> print_freshness_field;
  [%expect
    {| level=library_overview describe_freshness=snapshot drifted=false endpoint=dune-rpc:8 |}]

let%expect_test "path form has no describe_freshness" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  Docs.run ~sandbox ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "lib/demo/demo.mli")
  |> print_freshness_field;
  [%expect {| level=file_outline describe_freshness=none |}]

let%expect_test "path form threads a multi-token merlin program prefix" =
  with_fixture @@ fun ~process_mgr ~clock ~fs ~cwd ~workspace ->
  with_temp_dir @@ fun bin ->
  let merlin = path bin "fake-merlin" in
  write_disk merlin
    "#!/bin/sh\n\
     if [ \"$1\" = \"WRAPPED\" ] && [ \"$2\" = \"single\" ]; then\n\
    \  printf '{\"class\":\"return\",\"value\":[]}\\n'\n\
     else\n\
    \  printf 'bad argv: %s\\n' \"$*\" >&2\n\
    \  exit 3\n\
     fi\n";
  Unix.chmod merlin 0o755;
  run ~program:[ merlin; "WRAPPED" ] ~process_mgr ~clock ~fs ~cwd ~workspace
    (Docs.Input.make "broken.ml");
  [%expect
    {|
    provenance: workspace file broken.ml
    level=file_outline interface_available=false library=- source=broken.ml
    items=0/0 offset=1 status=complete
    |}]

[%%run_tests "spice.tools.ocaml_docs.expect"]
