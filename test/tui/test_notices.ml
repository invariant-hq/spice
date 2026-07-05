(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Blackbox pty tests for the live Dune data notices — the watcher speaking
   during chat (doc/ui-design/01-transcript.md §Notices, data class). The home
   brief tick that carries dune health stops at the drop, so the runtime watches
   dune health with its own chat-phase poll; the footer must stay live across the
   whole conversation and clean↔broken transitions must surface as coalescing
   [⊙ dune] notices.

   What is drivable here is the FEED and its guard. The harness's external
   [dune --watch] connects but cannot compile — it builds temp fixtures with the
   repo's dune-managed toolchain, which is not on PATH for a bare fixture (see
   test_home_live.ml's dune-flip caveat) — so [build_health] settles at [Unknown]
   (connected, no diagnostics latched) and never at [Clean] or [Failing]. That is
   enough to prove the footer's dune verdict is watched live in chat, and that a
   verdict-less connectivity change fires no build notice. It is NOT enough to
   drive a real break or heal: emitting [⊙ dune · build broken · N errors] and
   [⊙ dune · build clean · Ns broken], and the two-break coalescing, all require a
   [Clean]/[Failing] verdict the harness cannot produce. Those paths are the
   transition law in app.ml [apply_health] and the coalescing law in
   transcript.ml [append]; driving them end-to-end would need a fake health seam,
   which this suite does not use. *)

open Tui_harness

let reduced_motion = [ ("SPICE_REDUCED_MOTION", "1") ]
let print_fact = Util.print_fact

let run ?env ?rows ?cols ?provider project f =
  Term.run ?env ?rows ?cols ?provider project f

(* The footer's dune verdict is watched live during chat, not frozen at the drop.
   The home shows no dune (none is running), so the chat opens with the footer
   reading [dune: ✗]. A [dune --watch] then comes up mid-conversation: the
   chat-phase health poll — which the prelude brief tick would otherwise carry —
   discovers it and the footer flips to [dune: ✓] with no brief tick in play. The
   connection latches no build verdict in the harness (it settles at Unknown), so
   the glyph moves on connectivity alone and no [⊙ dune] build notice is recorded:
   Unknown is no verdict, and the transition law fires only on clean↔broken. *)
let%expect_test "the footer's dune verdict is watched live during chat" =
  Project.with_temp "next-notices-live" @@ fun project ->
  let answer = "Watching the build now." in
  Provider.with_openai project ~answer ~body_contains:[ "watch" ]
  @@ fun provider ->
  run project ~provider ~env:reduced_motion ~rows:24 ~cols:80 @@ fun t ->
  Term.wait t (Screen.has "dune:");
  Term.send t "watch the build";
  Term.wait t (Screen.has "❯ watch the build");
  Term.send t Keys.enter;
  Term.wait t (fun s -> Screen.has answer s && Screen.has "? for shortcuts" s);
  print_fact "chat footer starts disconnected"
    (Screen.has "dune: ✗" (Term.screen t));
  Project.with_external_dune_watch project @@ fun () ->
  Term.wait ~deadline:40.0 t (fun s ->
      Screen.has "dune: ✓" s && Screen.lacks "dune: ✗" s);
  print_fact "chat footer flips to connected live"
    (Screen.has "dune: ✓" (Term.screen t)
    && Screen.lacks "dune: ✗" (Term.screen t));
  print_fact "no build notice on a verdict-less connectivity change"
    (Screen.lacks "⊙ dune" (Term.screen t)
    && Screen.lacks "build broken" (Term.screen t)
    && Screen.lacks "build clean" (Term.screen t));
  [%expect
    {|chat footer starts disconnected: true
chat footer flips to connected live: true
no build notice on a verdict-less connectivity change: true|}]

[%%run_tests "spice.tui-next.notices"]
