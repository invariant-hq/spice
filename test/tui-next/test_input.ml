(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_next_harness

(* Input robustness. The composer must survive real terminal input the old suite
   never exercised: wide (CJK) and multi-byte (accented, emoji) graphemes, edits
   interleaved with cursor motion, and a bracketed paste carrying Unicode. Bytes
   flow through the real Matrix parser (the harness feeds raw bytes), so these
   also guard the UTF-8 decode path. One test keeps the ctrl+o verbose-lens
   decode under a golden — the known-regression class from the old
   test_strip/test_transcript, where 0x0F stopped decoding as Ctrl+O. *)

(* Wide and multi-byte graphemes land in the composer at their display width:
   CJK occupies two cells each, the accented e and the emoji render, and the
   draft round-trips through the byte parser intact. *)
let%expect_test "wide and multi-byte characters land in the composer" =
  Tui.run ~name:"input-unicode" @@ fun t ->
  Tui.settle t;
  Tui.keys t "日本語 café 🎉 test";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ 日本語 café 🎉 test
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |                      account    none — /login to connect
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   ! not logged in · /login · …i-next-input-unicode · gpt-5.5 medium · dune: ✗|}]

(* Editing interleaved with cursor motion: type a word, walk the cursor left
   into it, and insert — the character lands at the cursor, not the end, proving
   the composer tracks the caret across byte-fed left-arrows. *)
let%expect_test "interleaved typing and cursor motion edit in place" =
  Tui.run ~name:"input-interleave" @@ fun t ->
  Tui.settle t;
  Tui.keys t "abcd";
  Tui.keys t Keys.left;
  Tui.keys t Keys.left;
  Tui.keys t "X";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ abXcd
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |                      account    none — /login to connect
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   ! not logged in · /login · …ext-input-interleave · gpt-5.5 medium · dune: ✗|}]

(* A short (sub-threshold) bracketed paste carrying Unicode inserts inline as
   normal draft text rather than collapsing to a [Pasted text] chunk — the
   collapse is for large multi-line pastes (covered in test_composer). *)
let%expect_test "a small unicode paste inserts inline" =
  Tui.run ~name:"input-paste" @@ fun t ->
  Tui.settle t;
  Tui.paste t "naïve — 日本語";
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |
03 |
04 |                              ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·
05 |                              ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂
06 |
07 |                            dev · openai/gpt-5.5 medium
08 |
09 |      ▎ welcome — and thanks for trying spice this early.
10 |      ▎ it's experimental: sessions and config may change without migration.
11 |
12 |           ────────────────────────────────────────────────────────────
13 |           ❯ naïve — 日本語
14 |           ────────────────────────────────────────────────────────────
15 |
16 |                      dune       ✗ · diagnostics unavailable
17 |                      account    none — /login to connect
18 |
19 |                       sandbox: danger-full-access (config)
20 |
21 |
22 |
23 |
24 |   ! not logged in · /login · …tui-next-input-paste · gpt-5.5 medium · dune: ✗|}]

(* The ctrl+o verbose lens on the transcript. This pins whatever the byte
   0x0F currently decodes to: a working ctrl+o raises the verbose row, a
   regressed decode inserts a literal control glyph or no-ops. Golden the current
   behavior so a decode fix (or regression) flips the frame loudly. *)
let%expect_test "ctrl+o on the transcript (regression guard)" =
  let script =
    [
      Provider.message ~expect:[ "say hello" ] ~gate:"fin" ~id:"resp-1"
        "Hello from spice.";
    ]
  in
  Tui.run ~name:"input-ctrlo" ~provider:script @@ fun t ->
  Tui.settle t;
  Tui.keys t "say hello";
  Tui.enter t;
  ignore (Tui.await_request t 1 : string);
  Tui.release t "fin";
  Tui.settle t;
  Tui.keys t Keys.ctrl_o;
  Tui.settle t;
  Tui.print t;
  [%expect
    {|01 |
02 |  ▄▀▀ █▀▄ · ▄▀▀ ██▀   ·    dev · openai/gpt-5.5 medium
03 |  ▄██ █▀  █ ▀▄▄ █▄▄ ▂▄▆▄▂  $PROJECT
04 |        sandbox: danger-full-access (config)
05 |
06 | ❯ say hello
07 |
08 | ⏺ Hello from spice.
09 |
10 |
11 |
12 |
13 |
14 |
15 |
16 |
17 |
18 |
19 |
20 |   ◎ verbose ctrl+o closes
21 | ────────────────────────────────────────────────────────────────────────────────
22 | ❯ message spice
23 | ────────────────────────────────────────────────────────────────────────────────
24 |   …/tmp/spice-tui-next-input-ctrlo · gpt-5.5 medium · dune: ✗  ? for shortcuts|}]
