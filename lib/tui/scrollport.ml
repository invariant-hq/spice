(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

let view ?(key = "transcript.scrollport") ?reveal ?on_scroll children =
  scroll_box ~key ~scroll_y:true ~sticky_scroll:true
    ~sticky_start:`Bottom
      (* No scrollbar ever (01-transcript.md §Seam replay, scroll, spacing):
       position is felt, not shown — the transcript is a stream, not a pane.
       The scroll box defaults [show_scrollbars] to true, so the wrapper pins
       it off; scrolling still works. *)
    ~show_scrollbars:false
      (* A scroll box force-enables [focusable] in its own construction
       (scroll_box force-sets it true after props are applied, so the element's
       [focusable:false] cannot win), and the transcript must never take focus
       away from the composer. The ref turns it back off once the node exists. *)
    ~focusable:false
    ~ref:(fun node -> Mosaic_ui.Renderable.set_focusable node false)
      (* The scroll box scrolls on a wheel event but does not stop it, so the
       event keeps bubbling to the app root; stopping it here keeps one wheel
       tick from scrolling the transcript twice through an ancestor handler. *)
    ~on_mouse:(fun ev ->
      (match Event.Mouse.kind ev with
      | Event.Mouse.Scroll _ -> Event.Mouse.stop_propagation ev
      | _ -> ());
      None)
    ?reveal ?on_scroll ~flex_grow:1. ~flex_shrink:1.
    ~size:{ width = pct 100; height = px 0 }
    children
