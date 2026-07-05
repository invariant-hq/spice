(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The transcript viewport (01-transcript.md §Seam replay, scroll, spacing).

    The one sanctioned wrapper over {!Mosaic.scroll_box}: a sticky-bottom
    viewport that follows new content, never takes keyboard focus, and renders
    no scrollbar at any overflow (01-transcript.md §Seam replay, scroll,
    spacing: the transcript shows position through content alone, never a bar).
    The scroll-box workarounds the transcript needs live here alone, each named
    at its call site — no other surface reaches for them. *)

val view :
  ?key:string ->
  ?reveal:Mosaic.Scroll_box.reveal ->
  ?on_scroll:(x:int -> y:int -> 'msg option) ->
  'msg Mosaic.t list ->
  'msg Mosaic.t
(** [view children] is the transcript viewport holding [children], scrolling
    vertically and sticking to the bottom. [reveal] issues a one-shot scroll to
    a content coordinate (PageUp/Down paging is driven from the app), and
    [on_scroll] reports the settled position. The viewport grows to fill the
    space it is given. *)
