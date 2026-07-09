(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The slow session facts, assembled at launch and refreshed on change.

    This is tui-next's own status projection (doc/plans/tui-next.md, "tui-next
    builds its own snapshot from host calls"): version, model, cwd, the context
    window, and any non-default permission/sandbox posture. The live facts
    (dune, worktree, CRs, last session) are the {!Home.Brief.t}; the two are
    kept apart because they refresh on different clocks (04-header-footer.md,
    "Header vs footer"). Version, cwd, and posture are process-static; the model
    facts track the session's turn binding — a /model pick or a login that flips
    the derived default pushes a rebuilt snapshot, so the footer never shows a
    model the next turn would not use. A banner already appended to the
    transcript keeps the facts it recorded; it is a session-start record, not a
    live readout.

    The record is transparent: the surfaces that render it (banner, footer)
    construct their views directly from these fields, and the runtime is the one
    impure builder. *)

type t = {
  version : string;
      (** Build version, ["dev"] or a ["v"]-prefixed release (e.g. ["v0.3.0"]).
      *)
  model : string;  (** The main model as ["provider/model"], not truncated. *)
  effort : string option;
      (** Reasoning effort label, when the model carries one. *)
  cwd : Spice_path.Abs.t;  (** The workspace root. *)
  context_window : int option;
      (** The main model's context window in tokens, when the catalog knows it —
          the denominator of the footer meter. *)
  permission : string option;
      (** Non-default permission posture as a hanging-line label (e.g.
          ["never ask"]); [None] when the posture is the default ask-first. Only
          the compact banner record shows it (04-header-footer.md §1). *)
  sandbox : string option;
      (** Configured sandbox as a hanging-line label (e.g.
          ["danger-full-access (config)"]); [None] when no sandbox is
          configured. Only the compact banner record shows it. *)
}
(** The type for the static session facts. *)

val equal : t -> t -> bool
(** [equal a b] is field-wise equality. The shell uses it to drop a pushed
    refresh that changed nothing, keeping the model physically equal for
    memoized renders. *)

val model_line : t -> string
(** [model_line t] is the banner's model fact: ["provider/model effort"], or
    just ["provider/model"] when no effort is carried (08-brand.md, model beside
    the lockup). *)

val model_line_compact : t -> string
(** [model_line_compact t] is the footer's model fact: the last ["/"] segment of
    the model with the effort appended (["gpt-5.5 medium"]), the terse durable
    readout (04-header-footer.md §2). *)
