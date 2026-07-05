(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The farewell printed to the terminal once the TUI exits.

    Rendered outside Mosaic and written to stdout after the alternate screen has
    restored ({!Runtime}), so it lands on the normal terminal as the parting
    frame. *)

val render : color:bool -> session:Spice_session.Id.t option -> string
(** [render ~color ~session] is the goodbye text: the two-row brand lockup
    ({!Theme.lockup}) and, when [session] is [Some id], a muted line naming the
    resume command [spice resume ID]. A prelude quit with no session ([None])
    prints the lockup alone, mirroring the old TUI's no-session exit.

    [color] toggles the {!Theme.accent} and {!Theme.muted} ANSI styling; [false]
    emits plain text for [NO_COLOR] and non-color terminals. The result opens and
    closes with a blank line and ends in a newline, ready to write verbatim. *)
