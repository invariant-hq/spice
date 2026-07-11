(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Notices — the six classes, one form each (01-transcript.md §Notices).

    A notice is not free text: it belongs to exactly one class, and each class
    has a single committed form. Because {!t} is a closed sum over the classes,
    a new notice cannot be written without naming the class it joins — new forms
    are prohibited by construction, not by review. *)

(** A fact in a data notice. *)
type fact =
  | Fact of string  (** a countable fact, muted *)
  | Change of { added : int; removed : int }
      (** the [+A −D] pair — the success/error colors a notice may show
          (01-transcript.md §Data notices). *)
  | Errors of int
      (** a build error count: the number in [error], the noun muted. The one
          error color a build notice shows — the word ([build broken]) stays
          muted, only the count is red (01-transcript.md §Data notices, dune).
      *)

type t =
  | Event of string
      (** An indent-2 muted line with no glyph: a mode toggle, a rename, an
          answer submitted, a background job finished. Any glyph the line needs
          (e.g. [⏸] for plan mode) travels inside the string. *)
  | Echo of { command : string; result : string option }
      (** A stateful slash command echoed back: muted [❯ /command] and its muted
          result. Overlay-openers do not echo. *)
  | Interrupt
      (** The single interrupt line:
          [◌ Interrupted — tell spice what to do differently.] *)
  | Failure of { message : string; next_step : string; count : int }
      (** A provider, tool, or session error: a [✗] error line and a muted
          next-step line saying what happens now. [count] renders as [ × N] when
          the same failure repeats and is folded by the emitter. *)
  | Seam of string
      (** A labeled boundary rule (78 columns, centered): [compacted],
          [resumed · N messages · age], and the like — the only labeled rules in
          the transcript. The string is the label. *)
  | Data of {
      source : string;
      facts : fact list;
      atom : string option;
      disclosable : bool;
    }
      (** The world speaking ([⊙]): a watcher naming its [source], carrying
          countable [facts], and offering at most one slash [atom].
          [disclosable] names hidden detail; no glyph marks it until the
          disclosure mechanism can actually expand a notice in place. *)

val view : t -> _ Mosaic.t
(** [view t] renders the notice in its class's committed form. *)
