(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The status strip: the transient rows directly above the composer's top rule
    (01-transcript.md §The status strip).

    The strip hosts everything transient — each row exists only while its
    condition holds, and the strip is usually absent. This iteration renders two
    tenants: the ctrl+o verbose lens announcing itself, and one row per queued
    prompt. Background-job rows and the task board rule land with their host
    support and are not modeled here.

    The strip is the composer's margin (fixed chrome), not part of the
    scrollport — unlike the working line it never enters scrollback.

    The queue never captures esc (01-transcript.md §The status strip, revised
    2026-07-08): esc always belongs to interrupt/force, so a wrong-direction
    turn stops in one gesture even while a correction sits queued. The queue's
    own edit key is [↑], which the row names as [(↑ edits)]: with the composer
    empty and the queue non-empty, [↑] pops the newest queued prompt back for
    editing, ahead of prompt-history recall. The shell owns that routing (see
    [app.ml]'s [list_key]); this module only names the key in the row. *)

val view : width:int -> verbose:bool -> queued:string list -> _ Mosaic.t list
(** [view ~width ~verbose ~queued] is the strip's rows in spec order, or the
    empty list when no tenant is active (so the caller mounts it
    unconditionally):

    - [◎ verbose ctrl+o closes] in {!Theme.warning} while [verbose] — the ctrl+o
      global lens is on and announces itself only here.
    - one [↥ queued · "<first line>" (↑ edits)] row per prompt in [queued]
      (oldest first): the prompt's first line, quoted and truncated to [width],
      with the muted marker and the faint hint.

    [width] is the terminal column count; a long prompt truncates with an
    ellipsis so no row wraps. *)
