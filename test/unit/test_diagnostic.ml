(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Diagnostic = Spice_diagnostic

let make_invariants () =
  expect_invalid_arg "empty message raises" (fun () -> Diagnostic.make "");
  expect_invalid_arg "message rejects LF" (fun () ->
      Diagnostic.make "unknown\nkey");
  expect_invalid_arg "message rejects CR" (fun () ->
      Diagnostic.make "unknown\rkey");
  expect_invalid_arg "empty context raises" (fun () ->
      Diagnostic.make ~context:"" "unknown key");
  expect_invalid_arg "empty hint raises" (fun () ->
      Diagnostic.make ~hints:[ "first"; "" ] "unknown key");
  expect_invalid_arg "hint rejects LF" (fun () ->
      Diagnostic.make ~hints:[ "first\nsecond" ] "unknown key");
  expect_invalid_arg "hint rejects CR" (fun () ->
      Diagnostic.make ~hints:[ "first\rsecond" ] "unknown key");
  expect_invalid_arg "empty suggest candidate raises" (fun () ->
      Diagnostic.suggest [ "build"; "" ]);
  expect_invalid_arg "close empty did-you-mean candidate raises" (fun () ->
      Diagnostic.did_you_mean "x" ~candidates:[ "" ])

let rendering () =
  let plain = Diagnostic.make "unknown key" in
  equal string ~msg:"message only" "unknown key" (Diagnostic.to_string plain);
  let with_context =
    Diagnostic.make ~context:"in project config" "unknown key"
  in
  equal string ~msg:"context follows message on its own line"
    "unknown key\nin project config"
    (Diagnostic.to_string with_context);
  let with_hints = Diagnostic.make ~hints:[ "first"; "second" ] "unknown key" in
  equal string ~msg:"one Hint line per hint"
    "unknown key\nHint: first\nHint: second"
    (Diagnostic.to_string with_hints);
  let full =
    Diagnostic.make ~context:"in project config" ~hints:[ "first" ]
      "unknown key"
  in
  equal string ~msg:"context precedes hints"
    "unknown key\nin project config\nHint: first"
    (Diagnostic.to_string full)

let suggest () =
  equal (list string) ~msg:"empty candidates make no hint" []
    (Diagnostic.suggest []);
  equal (list string) ~msg:"one candidate" [ "did you mean build?" ]
    (Diagnostic.suggest [ "build" ]);
  equal (list string) ~msg:"two candidates joined with or"
    [ "did you mean build or plan?" ]
    (Diagnostic.suggest [ "build"; "plan" ]);
  equal (list string) ~msg:"three candidates use commas then or"
    [ "did you mean build, plan or review?" ]
    (Diagnostic.suggest [ "build"; "plan"; "review" ])

let did_you_mean () =
  let candidates = [ "build"; "plan"; "review" ] in
  equal (list string) ~msg:"distance one becomes a hint"
    [ "did you mean build?" ]
    (Diagnostic.did_you_mean "buld" ~candidates);
  equal (list string) ~msg:"distance two becomes a hint"
    [ "did you mean plan?" ]
    (Diagnostic.did_you_mean "pn" ~candidates);
  equal (list string) ~msg:"distance three is too far" []
    (Diagnostic.did_you_mean "rvw" ~candidates);
  equal (list string) ~msg:"close match becomes a hint"
    [ "did you mean build?" ]
    (Diagnostic.did_you_mean "biuld" ~candidates);
  equal (list string) ~msg:"several close matches share one hint"
    [ "did you mean bat or cat?" ]
    (Diagnostic.did_you_mean "hat" ~candidates:[ "bat"; "moon"; "cat" ]);
  equal (list string) ~msg:"no close match means no hint" []
    (Diagnostic.did_you_mean "deploy" ~candidates);
  equal (list string) ~msg:"exact match is never suggested" []
    (Diagnostic.did_you_mean "plan" ~candidates);
  equal (list string) ~msg:"empty candidates make no hint" []
    (Diagnostic.did_you_mean "anything" ~candidates:[]);
  equal (list string) ~msg:"empty input matches short candidates"
    [ "did you mean go?" ]
    (Diagnostic.did_you_mean "" ~candidates:[ "go"; "build" ]);
  let rendered =
    Diagnostic.to_string
      (Diagnostic.make
         ~hints:(Diagnostic.did_you_mean "biuld" ~candidates)
         "unknown workflow mode: biuld")
  in
  check "hint feeds make and reaches the rendered output"
    (Option.is_some
       (String.find_first ~sub:"Hint: did you mean build?" rendered))

let () =
  run "spice.diagnostic"
    [
      test "constructor validates invariants" make_invariants;
      test "renders message, context, and hints" rendering;
      test "formats suggestion hints" suggest;
      test "suggests close matches" did_you_mean;
    ]
