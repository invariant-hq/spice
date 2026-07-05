(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Anchor_tracker = Spice_tools.Anchor_tracker
module Resolver = Spice_tools.Anchor.Resolver
module W = Spice_workspace
module Path = Spice_path

let abs text =
  match Path.Abs.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Path.Error.pp error

let rel text =
  match Path.Rel.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Path.Error.pp error

let root = W.Root.make (abs "/workspace")
let path text = W.Path.make ~root (rel text)
let file = path "src/main.ml"
let other_file = path "src/other.ml"

let resolver ?max_files ?max_lines ?(seed = "session-1") () =
  Anchor_tracker.resolver (Anchor_tracker.create ?max_files ?max_lines ~seed ())

let expect_index ~msg result =
  match result with
  | Ok index -> index
  | Error error -> failf "%s: %a" msg Resolver.pp_error error

let expect_error ~msg result =
  match result with
  | Ok index -> failf "%s: expected error, resolved to line %d" msg index
  | Error error -> error

let is_anchor_word word =
  String.length word > 0
  && (match word.[0] with 'A' .. 'Z' -> true | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false)
       word

let source_line (resolver : Resolver.t) ~path ~number ~text =
  Spice_tools.Anchor.Source.line resolver.Resolver.source ~path ~number ~text
  |> Option.map Spice_tools.Anchor.to_string

(* Cap validation *)

let create_rejects_nonpositive_caps () =
  raises_invalid_arg ~msg:"non-positive max_files"
    "Spice_tools.Anchor_tracker.create: max_files must be positive" (fun () ->
      Anchor_tracker.create ~max_files:0 ~seed:"s" ());
  raises_invalid_arg ~msg:"non-positive max_lines"
    "Spice_tools.Anchor_tracker.create: max_lines must be positive" (fun () ->
      Anchor_tracker.create ~max_lines:0 ~seed:"s" ())

(* Reconcile and resolve *)

let lines_a = [ "let a = 1"; "let b = 2"; "let c = 3" ]

let resolve_after_reconcile () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  (* Recover the anchors through the source view. *)
  let anchors =
    List.mapi
      (fun i text ->
        match source_line r ~path:file ~number:(i + 1) ~text with
        | Some anchor -> anchor
        | None -> failf "no anchor for line %d" (i + 1))
      lines_a
  in
  List.iter
    (fun anchor ->
      is_true ~msg:("anchor word shape: " ^ anchor) (is_anchor_word anchor))
    anchors;
  List.iteri
    (fun i anchor ->
      let index =
        expect_index ~msg:"resolve"
          (r.Resolver.resolve ~path:file ~anchor ~expected:(List.nth lines_a i))
      in
      equal int ~msg:"resolved index" (i + 1) index)
    anchors

let mismatch_carries_expected_and_provided () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  let anchor =
    Option.get (source_line r ~path:file ~number:2 ~text:"let b = 2")
  in
  let error =
    expect_error ~msg:"mismatch"
      (r.Resolver.resolve ~path:file ~anchor ~expected:"let b = 99")
  in
  match error with
  | Resolver.Mismatch { expected; provided; _ } ->
      equal string ~msg:"expected is current file text" "let b = 2" expected;
      equal string ~msg:"provided is caller text" "let b = 99" provided
  | Resolver.Not_found _ -> failf "expected mismatch, got not-found"

let unknown_anchor_not_found () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  match
    expect_error ~msg:"unknown anchor"
      (r.Resolver.resolve ~path:file ~anchor:"NopeNada" ~expected:"let a = 1")
  with
  | Resolver.Not_found { anchor } ->
      equal string ~msg:"anchor name" "NopeNada" anchor
  | Resolver.Mismatch _ -> failf "expected not-found, got mismatch"

let untracked_file_not_found () =
  let r = resolver () in
  match
    expect_error ~msg:"untracked file"
      (r.Resolver.resolve ~path:file ~anchor:"AppleBanana" ~expected:"let a = 1")
  with
  | Resolver.Not_found _ -> ()
  | Resolver.Mismatch _ -> failf "expected not-found, got mismatch"

(* Reconciliation across edits *)

let anchors_survive_insertion () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  let anchor_c =
    Option.get (source_line r ~path:file ~number:3 ~text:"let c = 3")
  in
  (* Insert a new line at the top: unchanged lines keep their anchors and
     resolve to their shifted indexes. *)
  r.Resolver.reconcile ~path:file ~lines:("(* new *)" :: lines_a);
  let index =
    expect_index ~msg:"shifted resolve"
      (r.Resolver.resolve ~path:file ~anchor:anchor_c ~expected:"let c = 3")
  in
  equal int ~msg:"shifted index" 4 index

let changed_line_gets_fresh_anchor () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  let anchor_b =
    Option.get (source_line r ~path:file ~number:2 ~text:"let b = 2")
  in
  r.Resolver.reconcile ~path:file
    ~lines:[ "let a = 1"; "let b = 99"; "let c = 3" ];
  (match
     expect_error ~msg:"old anchor names old text"
       (r.Resolver.resolve ~path:file ~anchor:anchor_b ~expected:"let b = 2")
   with
  | Resolver.Not_found _ -> ()
  | Resolver.Mismatch _ -> failf "expected not-found for replaced line");
  let fresh =
    Option.get (source_line r ~path:file ~number:2 ~text:"let b = 99")
  in
  is_true ~msg:"changed line has a different anchor"
    (not (String.equal fresh anchor_b))

let identical_reconcile_is_stable () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  let before =
    Option.get (source_line r ~path:file ~number:1 ~text:"let a = 1")
  in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  let after =
    Option.get (source_line r ~path:file ~number:1 ~text:"let a = 1")
  in
  equal string ~msg:"identical contents keep anchors" before after

(* Determinism *)

let deterministic_allocation () =
  let observe seed =
    let r = resolver ~seed () in
    r.Resolver.reconcile ~path:file ~lines:lines_a;
    List.mapi
      (fun i text ->
        Option.get (source_line r ~path:file ~number:(i + 1) ~text))
      lines_a
  in
  equal (list string) ~msg:"same seed, same anchors" (observe "seed-a")
    (observe "seed-a");
  is_true ~msg:"different seed, different anchors"
    (not (List.equal String.equal (observe "seed-a") (observe "seed-b")))

(* Source view *)

let source_assigns_in_order () =
  let r = resolver () in
  (* A read render: sequential queries from line 1 establish tracking. *)
  let a1 = Option.get (source_line r ~path:file ~number:1 ~text:"alpha") in
  let _a2 = Option.get (source_line r ~path:file ~number:2 ~text:"beta") in
  let index =
    expect_index ~msg:"resolve after render"
      (r.Resolver.resolve ~path:file ~anchor:a1 ~expected:"alpha")
  in
  equal int ~msg:"line one" 1 index

let source_lookup_declines_on_drift () =
  let r = resolver () in
  r.Resolver.reconcile ~path:file ~lines:lines_a;
  (* Non-sequential observation (a search hit): matching text answers from
     tracked state, drifted text declines. *)
  is_true ~msg:"matching lookup answers"
    (Option.is_some (source_line r ~path:file ~number:2 ~text:"let b = 2"));
  is_true ~msg:"drifted lookup declines"
    (Option.is_none (source_line r ~path:file ~number:2 ~text:"let b = 99"))

let source_render_survives_external_edit () =
  let r = resolver () in
  let anchor_b =
    let _ = Option.get (source_line r ~path:file ~number:1 ~text:"alpha") in
    let anchor = Option.get (source_line r ~path:file ~number:2 ~text:"beta") in
    let _ = Option.get (source_line r ~path:file ~number:3 ~text:"gamma") in
    anchor
  in
  (* Re-render after an unrelated edit inserted a first line: the unchanged
     line keeps its anchor. *)
  let _ = Option.get (source_line r ~path:file ~number:1 ~text:"inserted") in
  let _ = Option.get (source_line r ~path:file ~number:2 ~text:"alpha") in
  let anchor_b' =
    Option.get (source_line r ~path:file ~number:3 ~text:"beta")
  in
  equal string ~msg:"anchor survives unrelated insertion" anchor_b anchor_b'

(* Caps and eviction *)

let file_cap_evicts_lru () =
  let r = resolver ~max_files:1 () in
  r.Resolver.reconcile ~path:file ~lines:[ "alpha" ];
  let anchor = Option.get (source_line r ~path:file ~number:1 ~text:"alpha") in
  r.Resolver.reconcile ~path:other_file ~lines:[ "beta" ];
  match
    expect_error ~msg:"evicted file"
      (r.Resolver.resolve ~path:file ~anchor ~expected:"alpha")
  with
  | Resolver.Not_found _ -> ()
  | Resolver.Mismatch _ -> failf "expected not-found after eviction"

let line_cap_untracks () =
  let r = resolver ~max_lines:2 () in
  r.Resolver.reconcile ~path:file ~lines:[ "alpha"; "beta" ];
  let anchor = Option.get (source_line r ~path:file ~number:1 ~text:"alpha") in
  r.Resolver.reconcile ~path:file ~lines:[ "alpha"; "beta"; "gamma" ];
  match
    expect_error ~msg:"over the line cap"
      (r.Resolver.resolve ~path:file ~anchor ~expected:"alpha")
  with
  | Resolver.Not_found _ -> ()
  | Resolver.Mismatch _ -> failf "expected not-found past the line cap"

let () =
  run "spice.tools.anchor_tracker"
    [
      test "create rejects non-positive caps" create_rejects_nonpositive_caps;
      test "resolve after reconcile" resolve_after_reconcile;
      test "mismatch carries expected and provided text"
        mismatch_carries_expected_and_provided;
      test "unknown anchors are not found" unknown_anchor_not_found;
      test "untracked files are not found" untracked_file_not_found;
      test "anchors survive insertions" anchors_survive_insertion;
      test "changed lines get fresh anchors" changed_line_gets_fresh_anchor;
      test "identical reconcile keeps anchors" identical_reconcile_is_stable;
      test "allocation is deterministic per seed" deterministic_allocation;
      test "source assigns anchors for in-order renders" source_assigns_in_order;
      test "source lookups decline on drift" source_lookup_declines_on_drift;
      test "rendered anchors survive external edits"
        source_render_survives_external_edit;
      test "file cap evicts least-recently-used" file_cap_evicts_lru;
      test "line cap untracks the file" line_cap_untracks;
    ]
