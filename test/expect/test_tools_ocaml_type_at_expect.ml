(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Type_at = Spice_tools.Ocaml_type_at
module Json = Jsont.Json
module Tool = Spice_tool
module Workspace = Spice_workspace

let sandbox = Spice_sandbox.seal Spice_sandbox.Policy.direct

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

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

let read_lines file =
  if not (Sys.file_exists file) then []
  else begin
    let ic = open_in file in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line -> loop (line :: acc)
          | exception End_of_file -> List.rev acc
        in
        loop [])
  end

let with_temp_dir f =
  let dir = Filename.temp_file "spice-ocaml-type-at-" ".tmp" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f (Unix.realpath dir))

let write_project root =
  write_disk (path root "dune-project") "(lang dune 3.0)\n(name fixture)\n";
  write_disk (path root "lib/dune") "(library (name fixture_lib))\n";
  write_disk (path root "lib/main.ml") "let answer = 42\nlet use = answer\n"

(* Fake [ocamlmerlin]: hard-fails without the [single] selector, logs its full
   argv (one line per subprocess) for count and selector assertions, drains the
   piped source, then runs the case-specific [body]. *)
let fake_log root = path root "merlin.log"

let write_fake root body =
  let log = fake_log root in
  let preamble =
    String.concat "\n"
      [
        "#!/bin/sh";
        "if [ \"$1\" != \"single\" ]; then";
        "  printf 'fake-ocamlmerlin: missing single selector\\n' >&2";
        "  exit 3";
        "fi";
        "printf '%s\\n' \"$*\" >> " ^ Filename.quote log;
        "cat >/dev/null";
        "";
      ]
  in
  let script = path root "fake-ocamlmerlin" in
  write_disk script (preamble ^ body);
  Unix.chmod script 0o755;
  script

let with_project f =
  with_temp_dir @@ fun root ->
  write_project root;
  let workspace = Workspace.single (Workspace.Root.make (abs root)) in
  Eio_main.run @@ fun env -> f ~root ~fs:(Eio.Stdenv.fs env) ~workspace

let decode_call tool input =
  match Tool.Call.decode [ tool ] ~name:Type_at.name ~input () with
  | Ok call -> call
  | Error error -> failf "decode failed: %a" Tool.Error.pp error

let run_tool ?cancelled ~root ~fs ~workspace ~body input =
  let merlin = write_fake root body in
  let tool = Type_at.tool ~sandbox ~program:[ merlin ] ~fs ~workspace () in
  let call = decode_call tool input in
  Tool.Call.run call ?cancelled ()

let position_input ?max_enclosings ?verbosity ?documentation ~line ~column () =
  let fields =
    [
      ("path", Json.string "lib/main.ml");
      ("line", Json.int line);
      ("column", Json.int column);
    ]
    @ (match max_enclosings with
      | None -> []
      | Some n -> [ ("max_enclosings", Json.int n) ])
    @ (match verbosity with
      | None -> []
      | Some n -> [ ("verbosity", Json.int n) ])
    @
    match documentation with
    | None -> []
    | Some b -> [ ("documentation", Json.bool b) ]
  in
  json_obj fields

let print_status result =
  match Tool.Result.status result with
  | Tool.Result.Completed -> print_endline "status: completed"
  | Tool.Result.Failed { kind; message; metadata } ->
      ignore metadata;
      Printf.printf "status: failed %s: %s\n"
        (Tool.Result.failure_to_string kind)
        message
  | Tool.Result.Interrupted { reason; cancelled } ->
      Printf.printf "status: interrupted cancelled=%b: %s\n" cancelled reason

let print_documentation = function
  | Type_at.Documentation.Not_requested ->
      print_endline "documentation: not_requested"
  | Type_at.Documentation.Not_available reason ->
      Printf.printf "documentation: not_available %s\n" reason
  | Type_at.Documentation.Available { text; truncated } ->
      Printf.printf "documentation: available truncated=%b %S\n" truncated text

let print_output result =
  print_status result;
  match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Type_at.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence ->
          Printf.printf "frames: %d\n"
            (List.length (Type_at.Output.frames evidence));
          Printf.printf "verbosity: %d\n" (Type_at.Output.verbosity evidence);
          print_documentation (Type_at.Output.documentation evidence);
          print_endline (Tool.Output.text output))

let print_subprocesses root =
  Printf.printf "subprocesses: %d\n" (List.length (read_lines (fake_log root)))

(* Envelope helpers for building canned type-enclosing responses. *)
let frame ~sl ~sc ~el ~ec ty =
  Printf.sprintf
    "{\"start\":{\"line\":%d,\"col\":%d},\"end\":{\"line\":%d,\"col\":%d},\"type\":%s,\"tail\":\"no\"}"
    sl sc el ec ty

let return_frames frames =
  Printf.sprintf "{\"class\":\"return\",\"value\":[%s]}\\n"
    (String.concat "," frames)

let print_out fmt = Printf.ksprintf (fun s -> "printf '" ^ s ^ "'") fmt

(* -- Tests ---------------------------------------------------------------- *)

let%expect_test "innermost type at default depth is one subprocess" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ])
    ^ "\n    ;;\n" ^ "  *) "
    ^ print_out "%s" "{\"class\":\"return\",\"value\":\"?\"}\\n"
    ^ " ;;\n" ^ "esac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    backend: ocamlmerlin
    subprocesses: 1 |}]

let%expect_test
    "enclosing stack returns frames innermost-first, one process per frame" =
  with_project @@ fun ~root ~fs ~workspace ->
  let f0 s = frame ~sl:1 ~sc:4 ~el:1 ~ec:7 s in
  let f1 s = frame ~sl:1 ~sc:0 ~el:1 ~ec:20 s in
  let f2 s = frame ~sl:1 ~sc:0 ~el:1 ~ec:40 s in
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" -index 0 \"*)";
        "    " ^ print_out "%s" (return_frames [ f0 "\"int\""; f1 "1"; f2 "2" ]);
        "    ;;";
        "  *\" -index 1 \"*)";
        "    "
        ^ print_out "%s" (return_frames [ f0 "0"; f1 "\"int list\""; f2 "2" ]);
        "    ;;";
        "  *\" -index 2 \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ f0 "0"; f1 "1"; f2 "\"int list list\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~max_enclosings:3 ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 3
    verbosity: 0
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    - lib/main.ml:1:0  int list
    - lib/main.ml:1:0  int list list
    backend: ocamlmerlin
    subprocesses: 3 |}]

let%expect_test "max_enclosings clamps to the real stack depth" =
  with_project @@ fun ~root ~fs ~workspace ->
  let f0 s = frame ~sl:1 ~sc:4 ~el:1 ~ec:7 s in
  let f1 s = frame ~sl:1 ~sc:0 ~el:1 ~ec:20 s in
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" -index 0 \"*)";
        "    " ^ print_out "%s" (return_frames [ f0 "\"int\""; f1 "1" ]);
        "    ;;";
        "  *\" -index 1 \"*)";
        "    " ^ print_out "%s" (return_frames [ f0 "0"; f1 "\"int list\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~max_enclosings:8 ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 2
    verbosity: 0
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    - lib/main.ml:1:0  int list
    backend: ocamlmerlin
    subprocesses: 2 |}]

let%expect_test "adjacent duplicate frames are deduplicated before limiting" =
  with_project @@ fun ~root ~fs ~workspace ->
  let dup = frame ~sl:1 ~sc:4 ~el:1 ~ec:7 in
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ dup "\"int\""; dup "\"int\"" ])
    ^ "\n    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    backend: ocamlmerlin
    subprocesses: 1 |}]

let%expect_test "empty enclosing list is a not_found with the position" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" "{\"class\":\"return\",\"value\":[]}\\n"
    ^ "\n    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:9 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: failed not_found: no type at position 1:9
    output: none
    subprocesses: 1 |}]

let%expect_test "verbosity is passed through and recorded" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" -verbosity 1 \"*)";
        "    "
        ^ print_out "%s"
            (return_frames
               [
                 frame ~sl:1 ~sc:4 ~el:1 ~ec:7
                   "\"{ host : string; port : int }\"";
               ]);
        "    ;;";
        "  *\" type-enclosing \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"Config.t\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~verbosity:1 ~line:1 ~column:4 ())
  |> print_output;
  Printf.printf "argv-has-verbosity: %b\n"
    (List.exists
       (fun l ->
         let re = " -verbosity 1 " in
         let l = " " ^ l ^ " " in
         let rec scan i =
           i + String.length re <= String.length l
           && (String.equal (String.sub l i (String.length re)) re
              || scan (i + 1))
         in
         scan 0)
       (read_lines (fake_log root)));
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 1
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  { host : string; port : int }
    backend: ocamlmerlin
    argv-has-verbosity: true |}]

let%expect_test "default verbosity omits the -verbosity flag entirely" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ])
    ^ "\n    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> ignore;
  Printf.printf "argv-mentions-verbosity: %b\n"
    (List.exists
       (fun l ->
         let rec scan i =
           i + 10 <= String.length l
           && (String.equal (String.sub l i 10) "-verbosity" || scan (i + 1))
         in
         scan 0)
       (read_lines (fake_log root)));
  [%expect {|
    argv-mentions-verbosity: false |}]

let%expect_test "an over-budget type string is truncated on a byte boundary" =
  with_project @@ fun ~root ~fs ~workspace ->
  (* Emit a ~5000-byte type string; the tool cuts it to the 4 KiB budget. *)
  let long_type =
    "$(i=0; while [ $i -lt 5000 ]; do printf a; i=$((i+1)); done)"
  in
  let body =
    "T=" ^ long_type ^ "\n" ^ "case \" $* \" in\n"
    ^ "  *\" type-enclosing \"*)\n"
    ^ "    printf \
       '{\"class\":\"return\",\"value\":[{\"start\":{\"line\":1,\"col\":4},\"end\":{\"line\":1,\"col\":7},\"type\":\"'\n"
    ^ "    printf '%s' \"$T\"\n" ^ "    printf '\",\"tail\":\"no\"}]}\\n'\n"
    ^ "    ;;\nesac\n"
  in
  let result =
    run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  in
  print_status result;
  (match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Type_at.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence ->
          let innermost = Type_at.Output.innermost evidence in
          Printf.printf "innermost truncated=%b bytes=%d\n"
            (Type_at.Frame.truncated innermost)
            (String.length (Type_at.Frame.type_string innermost))));
  [%expect {|
    status: completed
    innermost truncated=true bytes=4096 |}]

let%expect_test "documentation is fetched in an extra subprocess when requested"
    =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" document \"*)";
        "    "
        ^ print_out "%s" "{\"class\":\"return\",\"value\":\"The answer.\"}\\n";
        "    ;;";
        "  *\" type-enclosing \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~documentation:true ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: available truncated=false "The answer."
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    documentation: The answer.
    backend: ocamlmerlin
    subprocesses: 2 |}]

let%expect_test
    "a documentation sentinel becomes Not_available but keeps the type" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" document \"*)";
        "    "
        ^ print_out "%s"
            "{\"class\":\"return\",\"value\":\"No documentation available\"}\\n";
        "    ;;";
        "  *\" type-enclosing \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~documentation:true ~line:1 ~column:4 ())
  |> print_output;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: not_available No documentation available
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    documentation: unavailable (No documentation available)
    backend: ocamlmerlin |}]

let%expect_test "over-budget documentation text is truncated" =
  with_project @@ fun ~root ~fs ~workspace ->
  let long_doc =
    "$(i=0; while [ $i -lt 9000 ]; do printf d; i=$((i+1)); done)"
  in
  let body =
    "D=" ^ long_doc ^ "\n" ^ "case \" $* \" in\n" ^ "  *\" document \"*)\n"
    ^ "    printf '{\"class\":\"return\",\"value\":\"'\n"
    ^ "    printf '%s' \"$D\"\n" ^ "    printf '\"}\\n'\n" ^ "    ;;\n"
    ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ])
    ^ "\n    ;;\nesac\n"
  in
  let result =
    run_tool ~root ~fs ~workspace ~body
      (position_input ~documentation:true ~line:1 ~column:4 ())
  in
  print_status result;
  (match Tool.Result.output result with
  | None -> print_endline "output: none"
  | Some output -> (
      match Type_at.Output.of_tool_output output with
      | None -> print_endline "evidence: none"
      | Some evidence -> (
          match Type_at.Output.documentation evidence with
          | Type_at.Documentation.Available { truncated; text } ->
              Printf.printf "documentation available truncated=%b bytes=%d\n"
                truncated (String.length text)
          | Type_at.Documentation.Not_requested ->
              print_endline "documentation: not_requested"
          | Type_at.Documentation.Not_available reason ->
              Printf.printf "documentation: not_available %s\n" reason)));
  [%expect
    {|
    status: completed
    documentation available truncated=true bytes=8192 |}]

let%expect_test "the document not-found variant is not mistaken for doc text" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" document \"*)";
        "    "
        ^ print_out "%s"
            "{\"class\":\"return\",\"value\":\"answer was supposed to be in \
             fixture.cmi but could not be found\"}\\n";
        "    ;;";
        "  *\" type-enclosing \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~documentation:true ~line:1 ~column:4 ())
  |> print_output;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: not_available answer was supposed to be in fixture.cmi but could not be found
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    documentation: unavailable (answer was supposed to be in fixture.cmi but could not be found)
    backend: ocamlmerlin |}]

let%expect_test
    "a reconstructed string type at a non-queried index does not break decoding"
    =
  with_project @@ fun ~root ~fs ~workspace ->
  let f0 = frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" in
  (* Frame 1 carries a *string* type even though it is not the queried index. *)
  let f1 = frame ~sl:1 ~sc:0 ~el:1 ~ec:20 "\"Config.t\"" in
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ f0; f1 ])
    ^ "\n    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: completed
    frames: 1
    verbosity: 0
    documentation: not_requested
    OCaml type at lib/main.ml:1:4
    - lib/main.ml:1:4  int
    backend: ocamlmerlin
    subprocesses: 1 |}]

let%expect_test "every subprocess carries the single selector and -filename" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    String.concat "\n"
      [
        "case \" $* \" in";
        "  *\" document \"*)";
        "    " ^ print_out "%s" "{\"class\":\"return\",\"value\":\"A doc.\"}\\n";
        "    ;;";
        "  *\" type-enclosing \"*)";
        "    "
        ^ print_out "%s"
            (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ]);
        "    ;;";
        "esac";
        "";
      ]
  in
  run_tool ~root ~fs ~workspace ~body
    (position_input ~documentation:true ~line:1 ~column:4 ())
  |> ignore;
  List.iter
    (fun l ->
      let starts p = String.starts_with ~prefix:p l in
      let has_filename =
        let re = "-filename" in
        let rec scan i =
          i + String.length re <= String.length l
          && (String.equal (String.sub l i (String.length re)) re
             || scan (i + 1))
        in
        scan 0
      in
      Printf.printf "line ok: %b\n"
        ((starts "single type-enclosing " || starts "single document ")
        && has_filename))
    (read_lines (fake_log root));
  [%expect {|
    line ok: true
    line ok: true |}]

let%expect_test "a missing Merlin binary is Unavailable" =
  with_project @@ fun ~root:_ ~fs ~workspace ->
  let tool =
    Type_at.tool ~sandbox ~program:[ "/nonexistent/ocamlmerlin" ] ~fs
      ~workspace ()
  in
  let call = decode_call tool (position_input ~line:1 ~column:4 ()) in
  Tool.Call.run call () |> print_output;
  [%expect
    {|
    status: failed unavailable: could not start ocamlmerlin: No such file or directory in execvpe(/nonexistent/ocamlmerlin)
    output: none |}]

let%expect_test "a non-return envelope fails the call" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" "{\"class\":\"error\",\"value\":\"boom\"}\\n"
    ^ "\n    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> print_output;
  [%expect
    {|
    status: failed failed: ocamlmerlin returned error: boom
    output: none |}]

let%expect_test "a non-zero Merlin exit fails the call with its detail" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n"
    ^ "    printf 'merlin blew up\\n' >&2\n" ^ "    exit 2\n" ^ "    ;;\nesac\n"
  in
  run_tool ~root ~fs ~workspace ~body (position_input ~line:1 ~column:4 ())
  |> print_output;
  [%expect {|
    status: failed failed: merlin blew up
    output: none |}]

let%expect_test
    "a pre-cancelled context interrupts without spawning a subprocess" =
  with_project @@ fun ~root ~fs ~workspace ->
  let body =
    "case \" $* \" in\n" ^ "  *\" type-enclosing \"*)\n    "
    ^ print_out "%s" (return_frames [ frame ~sl:1 ~sc:4 ~el:1 ~ec:7 "\"int\"" ])
    ^ "\n    ;;\nesac\n"
  in
  run_tool
    ~cancelled:(fun () -> true)
    ~root ~fs ~workspace ~body
    (position_input ~line:1 ~column:4 ())
  |> print_output;
  print_subprocesses root;
  [%expect
    {|
    status: interrupted cancelled=true: tool call cancelled
    output: none
    subprocesses: 0 |}]

(* -- Input decoding (pure) ------------------------------------------------ *)

let print_decode label json =
  match Type_at.Input.decode json with
  | Ok input ->
      Printf.printf "%s: ok %s %d:%d max_enclosings=%d verbosity=%d doc=%b\n"
        label (Type_at.Input.path input)
        (Spice_ocaml.Position.line (Type_at.Input.position input))
        (Spice_ocaml.Position.column (Type_at.Input.position input))
        (Type_at.Input.max_enclosings input)
        (Type_at.Input.verbosity input)
        (Type_at.Input.documentation input)
  | Error message -> Printf.printf "%s: error %s\n" label message

let%expect_test "input contract validates coordinates and bounds" =
  print_decode "minimal"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
       ]);
  print_decode "explicit"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 2);
         ("column", Json.int 8);
         ("max_enclosings", Json.int 3);
         ("verbosity", Json.int 2);
         ("documentation", Json.bool true);
       ]);
  print_decode "bad line"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 0);
         ("column", Json.int 4);
       ]);
  print_decode "bad column"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int (-1));
       ]);
  print_decode "zero enclosings"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("max_enclosings", Json.int 0);
       ]);
  print_decode "too many enclosings"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("max_enclosings", Json.int 9);
       ]);
  print_decode "verbosity too high"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("verbosity", Json.int 4);
       ]);
  print_decode "unknown field"
    (json_obj
       [
         ("path", Json.string "lib/main.ml");
         ("line", Json.int 1);
         ("column", Json.int 4);
         ("expression", Json.string "List.map");
       ]);
  [%expect
    {|
    minimal: ok lib/main.ml 1:4 max_enclosings=1 verbosity=0 doc=false
    explicit: ok lib/main.ml 2:8 max_enclosings=3 verbosity=2 doc=true
    bad line: error line must be at least 1
    bad column: error column must be non-negative
    zero enclosings: error max_enclosings must be at least 1
    too many enclosings: error max_enclosings must be at most 8
    verbosity too high: error verbosity must be at most 3
    unknown field: error Unexpected member expression for ocaml_type_at input object |}]

[%%run_tests "spice.tools.ocaml_type_at.expect"]
