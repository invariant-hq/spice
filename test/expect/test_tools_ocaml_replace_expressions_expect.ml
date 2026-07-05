(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Json = Jsont.Json
module Replace = Spice_tools.Ocaml_replace_expressions
module Ocaml = Spice_ocaml
module Tool = Spice_tool
module Workspace = Spice_workspace
module Receipt = Spice_tools.Receipt

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

let join root rel = Filename.concat root rel

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
      | _ -> Unix.unlink path)

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
    (fun () -> output_string oc contents)

let read_disk file =
  let ic = open_in_bin file in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let with_files files f =
  let dir = Filename.temp_file "spice-ocaml-replace-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      List.iter
        (fun (rel, contents) -> write_disk (join dir rel) contents)
        files;
      let workspace = Workspace.single (Workspace.Root.make (abs dir)) in
      Eio_main.run @@ fun env -> f ~dir ~fs:(Eio.Stdenv.fs env) ~workspace)

let loc_text location =
  let range = Ocaml.Location.range location in
  let start = Ocaml.Range.start range in
  let end_ = Ocaml.Range.end_ range in
  Printf.sprintf "%d.%d-%d.%d"
    (Ocaml.Position.line start)
    (Ocaml.Position.column start)
    (Ocaml.Position.line end_)
    (Ocaml.Position.column end_)

let status_text = function
  | Replace.Output.Applied -> "applied"
  | Replace.Output.Previewed -> "previewed"

let skipped_text (s : Replace.Output.skipped) =
  let reason =
    match s.Replace.Output.reason with
    | Replace.Output.Binary -> "binary"
    | Replace.Output.Invalid_utf8 -> "invalid_utf8"
    | Replace.Output.Too_large -> "too_large"
    | Replace.Output.Syntax_error m -> "syntax_error(" ^ m ^ ")"
    | Replace.Output.Read_error m -> "read_error(" ^ m ^ ")"
    | Replace.Output.Unrenderable m -> "unrenderable(" ^ m ^ ")"
    | Replace.Output.Rewrite_unparsable m -> "rewrite_unparsable(" ^ m ^ ")"
  in
  Printf.sprintf "%s:%s"
    (Workspace.Path.display s.Replace.Output.skipped_path)
    reason

let op_label = function
  | Receipt.Create -> "A"
  | Receipt.Modify -> "M"
  | Receipt.Delete -> "D"
  | Receipt.Move _ -> "R"

let print_output ?(show_diff = false) output =
  Printf.printf "status=%s files=%d sites=%d searched=%d\n"
    (status_text (Replace.Output.status output))
    (List.length (Replace.Output.files output))
    (Replace.Output.total_sites output)
    (Replace.Output.searched_files output);
  List.iter
    (fun (f : Replace.Output.file) ->
      Printf.printf "  %s (%d sites)\n"
        (Workspace.Path.display f.Replace.Output.file_path)
        (List.length f.Replace.Output.sites);
      List.iter
        (fun (s : Replace.Output.site) ->
          Printf.printf "    %s: %S -> %S\n"
            (loc_text s.Replace.Output.location)
            s.Replace.Output.before s.Replace.Output.after)
        f.Replace.Output.sites;
      if show_diff then Printf.printf "    diff:\n%s" f.Replace.Output.diff)
    (Replace.Output.files output);
  (match Replace.Output.skipped output with
  | [] -> ()
  | skipped ->
      Printf.printf "skipped: %s\n"
        (String.concat " " (List.map skipped_text skipped)));
  let receipt = Replace.Output.receipt output in
  let changes = Receipt.changes receipt in
  if changes <> [] then
    Printf.printf "receipt: %s\n"
      (String.concat " "
         (List.map
            (fun (c : Receipt.change) ->
              op_label c.Receipt.op ^ " "
              ^ Workspace.Path.display c.Receipt.path)
            changes));
  match Replace.Output.final_identities output with
  | [] -> ()
  | ids ->
      Printf.printf "final_identities: %s\n"
        (String.concat " "
           (List.map (fun (path, _identity) -> Workspace.Path.display path) ids))

let print_result ?show_diff result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> print_output ?show_diff output
      | None -> print_endline "completed without output")
  | Tool.Result.Failed { kind; message; _ } ->
      Printf.printf "failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "interrupted cancelled=%b: %s\n" cancelled reason

let run ?show_diff ~fs ~workspace input =
  Replace.run ~fs ~workspace input |> print_result ?show_diff

let%expect_test "multi-file sweep applies and returns a receipt" =
  with_files
    [
      ( "lib/a.ml",
        "let f o = match o with None -> 0 | Some v -> v\n\
         let g o = match o with None -> base | Some w -> w\n" );
      ("lib/b.ml", "let h o = match o with None -> fallback () | Some x -> x\n");
    ]
  @@ fun ~dir ~fs ~workspace ->
  run ~fs ~workspace
    (Replace.Input.make ~pattern:"match __1 with None -> __2 | Some __3 -> __3"
       ~template:"Option.value __1 ~default:__2" ());
  Printf.printf "a.ml on disk:\n%s" (read_disk (join dir "lib/a.ml"));
  Printf.printf "b.ml on disk:\n%s" (read_disk (join dir "lib/b.ml"));
  [%expect
    {|
    status=applied files=2 sites=3 searched=2
      lib/a.ml (2 sites)
        1.10-1.46: "match o with None -> 0 | Some v -> v" -> "Option.value o ~default:0"
        2.10-2.49: "match o with None -> base | Some w -> w" -> "Option.value o ~default:base"
      lib/b.ml (1 sites)
        1.10-1.56: "match o with None -> fallback () | Some x -> x" -> "Option.value o ~default:(fallback ())"
    receipt: M lib/a.ml M lib/b.ml
    final_identities: lib/a.ml lib/b.ml
    a.ml on disk:
    let f o = Option.value o ~default:0
    let g o = Option.value o ~default:base
    b.ml on disk:
    let h o = Option.value o ~default:(fallback ()) |}]

let%expect_test "internal parenthesization and negative literals" =
  with_files
    [
      ("p.ml", "let a = x + 1 :: rest\n");
      ("n.ml", "let b = -1 :: rest\n");
      ("f.ml", "let c = -1.5 :: rest\n");
    ]
  @@ fun ~dir ~fs ~workspace ->
  let cons =
    Replace.Input.make ~pattern:"__1 :: __2" ~template:"List.cons __1 __2"
  in
  print_case "x + 1";
  run ~fs ~workspace (cons ~paths:[ "p.ml" ] ());
  print_case "-1";
  run ~fs ~workspace (cons ~paths:[ "n.ml" ] ());
  print_case "-1.5";
  run ~fs ~workspace (cons ~paths:[ "f.ml" ] ());
  Printf.printf "p.ml: %s" (read_disk (join dir "p.ml"));
  Printf.printf "n.ml: %s" (read_disk (join dir "n.ml"));
  Printf.printf "f.ml: %s" (read_disk (join dir "f.ml"));
  [%expect
    {|
    -- x + 1 --
    status=applied files=1 sites=1 searched=1
      p.ml (1 sites)
        1.8-1.21: "x + 1 :: rest" -> "List.cons (x + 1) rest"
    receipt: M p.ml
    final_identities: p.ml
    -- -1 --
    status=applied files=1 sites=1 searched=1
      n.ml (1 sites)
        1.8-1.18: "-1 :: rest" -> "List.cons (-1) rest"
    receipt: M n.ml
    final_identities: n.ml
    -- -1.5 --
    status=applied files=1 sites=1 searched=1
      f.ml (1 sites)
        1.8-1.20: "-1.5 :: rest" -> "List.cons (-1.5) rest"
    receipt: M f.ml
    final_identities: f.ml
    p.ml: let a = List.cons (x + 1) rest
    n.ml: let b = List.cons (-1) rest
    f.ml: let c = List.cons (-1.5) rest |}]

let%expect_test "template validation rejects unsound templates" =
  with_files [ ("x.ml", "let a = f b c\n") ] @@ fun ~dir:_ ~fs ~workspace ->
  let reject label ~pattern ~template =
    print_case label;
    run ~fs ~workspace (Replace.Input.make ~pattern ~template ())
  in
  reject "variable capture" ~pattern:"f __1 __2"
    ~template:"let tmp = __1 in tmp + __2";
  reject "capture under match arm" ~pattern:"f __1 __2"
    ~template:"match __1 with Some x -> f x __2 | None -> __2";
  reject "template metavar not in pattern" ~pattern:"f __1"
    ~template:"g __1 __2";
  reject "template uses wildcard" ~pattern:"f __1" ~template:"g __";
  reject "template not an expression" ~pattern:"f __1" ~template:"let x =";
  print_case "safe: hole in let rhs";
  run ~fs ~workspace
    (Replace.Input.make ~pattern:"f __1" ~template:"let x = __1 in x" ());
  [%expect
    {|
    -- variable capture --
    failed invalid_input: template hole __2 is in the scope of a let binder (tmp), which risks variable capture; keep template holes outside any binder the template introduces
    -- capture under match arm --
    failed invalid_input: template hole __2 is in the scope of a match/case binder (x), which risks variable capture; keep template holes outside any binder the template introduces
    -- template metavar not in pattern --
    failed invalid_input: template uses metavariable(s) __2 that the pattern does not bind
    -- template uses wildcard --
    failed invalid_input: the anonymous wildcard __ is pattern-only; a template needs a numbered hole like __1
    -- template not an expression --
    failed invalid_input: template is not a single OCaml expression at line 1, column 7
    -- safe: hole in let rhs --
    status=applied files=1 sites=1 searched=1
      x.ml (1 sites)
        1.8-1.13: "f b c" -> "let x = b in x"
    receipt: M x.ml
    final_identities: x.ml |}]

let%expect_test "dry run previews without writing" =
  with_files [ ("d.ml", "let a = x + 1 :: rest\n") ]
  @@ fun ~dir ~fs ~workspace ->
  run ~show_diff:true ~fs ~workspace
    (Replace.Input.make ~pattern:"__1 :: __2" ~template:"List.cons __1 __2"
       ~dry_run:true ());
  Printf.printf "d.ml unchanged on disk: %s" (read_disk (join dir "d.ml"));
  [%expect
    {|
    status=previewed files=1 sites=1 searched=1
      d.ml (1 sites)
        1.8-1.21: "x + 1 :: rest" -> "List.cons (x + 1) rest"
        diff:
    --- d.ml
    +++ d.ml
    @@ -1,1 +1,1 @@
    -let a = x + 1 :: rest
    +let a = List.cons (x + 1) rest
    d.ml unchanged on disk: let a = x + 1 :: rest |}]

let%expect_test "coverage evidence lists skipped files" =
  with_files
    [
      ("good.ml", "let a = List.rev xs @ ys\n");
      ("broken.ml", "let x =\n");
      ("blob.ml", "\000\000not ocaml\n");
    ]
  @@ fun ~dir:_ ~fs ~workspace ->
  run ~fs ~workspace
    (Replace.Input.make ~pattern:"List.rev __1 @ __2"
       ~template:"List.rev_append __1 __2" ());
  [%expect
    {|
    status=applied files=1 sites=1 searched=1
      good.ml (1 sites)
        1.8-1.24: "List.rev xs @ ys" -> "List.rev_append xs ys"
    skipped: blob.ml:binary broken.ml:syntax_error(syntax error at line 2, column 0)
    receipt: M good.ml
    final_identities: good.ml |}]

let%expect_test "max_sites bound fails and writes nothing" =
  with_files [ ("m.ml", "let a = f x\nlet b = f y\nlet c = f z\n") ]
  @@ fun ~dir ~fs ~workspace ->
  run ~fs ~workspace
    (Replace.Input.make ~pattern:"f __1" ~template:"g __1" ~max_sites:2 ());
  Printf.printf "m.ml unchanged: %s" (read_disk (join dir "m.ml"));
  [%expect
    {|
    failed failed: found 3 matching site(s), which exceeds max_sites=2; narrow paths or raise max_sites (nothing was written)
    m.ml unchanged: let a = f x
    let b = f y
    let c = f z |}]

let%expect_test "receipt names only successfully written files" =
  with_files
    [
      ("clean.ml", "let a = List.rev xs @ ys\n");
      ("bad.ml", "let x = List.rev xs @\n");
    ]
  @@ fun ~dir ~fs ~workspace ->
  run ~fs ~workspace
    (Replace.Input.make ~pattern:"List.rev __1 @ __2"
       ~template:"List.rev_append __1 __2" ());
  Printf.printf "clean.ml: %s" (read_disk (join dir "clean.ml"));
  Printf.printf "bad.ml: %s" (read_disk (join dir "bad.ml"));
  [%expect
    {|
    status=applied files=1 sites=1 searched=1
      clean.ml (1 sites)
        1.8-1.24: "List.rev xs @ ys" -> "List.rev_append xs ys"
    skipped: bad.ml:syntax_error(syntax error at line 2, column 0)
    receipt: M clean.ml
    final_identities: clean.ml
    clean.ml: let a = List.rev_append xs ys
    bad.ml: let x = List.rev xs @ |}]

let%expect_test "input decode" =
  let print_decode label json =
    let result =
      match Replace.Input.decode json with
      | Error _ -> "error"
      | Ok input ->
          Printf.sprintf
            "ok pattern=%s template=%s paths=%s max_sites=%s dry_run=%b"
            (Replace.Input.pattern input)
            (Replace.Input.template input)
            (match Replace.Input.paths input with
            | None -> "-"
            | Some paths -> String.concat "," paths)
            (match Replace.Input.max_sites input with
            | None -> "-"
            | Some n -> string_of_int n)
            (Replace.Input.dry_run input)
    in
    Printf.printf "%s: %s\n" label result
  in
  print_decode "minimal"
    (json_obj
       [ ("pattern", Json.string "f __1"); ("template", Json.string "g __1") ]);
  print_decode "full"
    (json_obj
       [
         ("pattern", Json.string "f __1");
         ("template", Json.string "g __1");
         ("paths", Json.list [ Json.string "lib" ]);
         ("max_sites", Json.int 10);
         ("dry_run", Json.bool true);
       ]);
  print_decode "unknown field"
    (json_obj
       [
         ("pattern", Json.string "f __1");
         ("template", Json.string "g __1");
         ("glob", Json.string "*.ml");
       ]);
  print_decode "missing template"
    (json_obj [ ("pattern", Json.string "f __1") ]);
  [%expect
    {|
    minimal: ok pattern=f __1 template=g __1 paths=- max_sites=- dry_run=false
    full: ok pattern=f __1 template=g __1 paths=lib max_sites=10 dry_run=true
    unknown field: error
    missing template: error |}]

let%expect_test "adapter permissions differ for apply and preview" =
  with_files [ ("z.ml", "let a = f x\n") ] @@ fun ~dir:_ ~fs ~workspace ->
  let tool = Replace.tool ~fs ~workspace () in
  let call ~dry_run =
    match
      Tool.Call.decode [ tool ] ~name:Replace.name
        ~input:
          (json_obj
             [
               ("pattern", Json.string "f __1");
               ("template", Json.string "g __1");
               ("dry_run", Json.bool dry_run);
             ])
        ()
    with
    | Ok call -> call
    | Error error -> failf "decode failed: %a" Tool.Error.pp error
  in
  Printf.printf "apply permissions=%d\n"
    (List.length (Tool.Call.permissions (call ~dry_run:false)));
  Printf.printf "preview permissions=%d\n"
    (List.length (Tool.Call.permissions (call ~dry_run:true)));
  [%expect {|
    apply permissions=1
    preview permissions=1 |}]

[%%run_tests "spice.tools.ocaml_replace_expressions.expect"]
