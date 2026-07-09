(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review screen frame: the two-pane split, header, bottom legend, help
    table, and the view-local orientation the component folds keys into.

    A persistent two-pane split — a directory-grouped nav on the left, the
    selected file's diff on the right, a full-height rule between — following
    the panel contract (rule, header, hint) but waiving the one-column law for
    this surface. This module is the pure view plus the focus transitions the
    component calls; key routing and effects live in the component. The state is
    exposed concretely so the component reads its orientation fields directly.
*)

(** The focused pane. [Queue] is nav focus, [Diff] is diff focus. The names
    predate the split and are kept because the component is wired to them. *)
type depth = Queue | Diff

type notice = { text : string; warning : bool }
(** A refresh/settle notice shown in place of the bottom legend until the next
    keypress. *)

type state = {
  depth : depth;  (** Which pane the movement keys drive. *)
  full_context : bool;  (** Whether the diff shows whole-file context. *)
  notice : notice option;  (** The active notice, if any. *)
  help : bool;  (** Whether the key table replaces the body. *)
  compose : Review_compose.t option;  (** The open compose dialog, if any. *)
}
(** The view-local orientation for one open review. Its review value is
    authoritative in the component; this holds only what the model cursor does
    not. Neither pane keeps a scroll offset: the nav windows on the cursor and
    the diff auto-reveals it, so a page key steps the cursor instead. *)

val init : state
(** [init] is the fresh orientation: nav focus, no notice, no dialog. *)

(** {1 Transitions} *)

val enter : state -> Spice_review.t -> state option
(** [enter state review] focuses the diff pane (enter on a nav row); [None] when
    already there or the cursor has no file to show. *)

val back : state -> state option
(** [back state] steps the esc ladder: diff focus returns to nav; nav focus
    returns [None] so the component closes the screen. *)

val toggle_focus : state -> state
(** [toggle_focus state] flips focus between the two panes (tab). *)

val set_compose : state -> Review_compose.t option -> state
(** [set_compose state compose] opens or closes the compose dialog. *)

val toggle_help : state -> state
(** [toggle_help state] flips the key table. *)

val toggle_context : state -> state
(** [toggle_context state] flips whole-file diff context. *)

val set_notice : state -> text:string -> warning:bool -> state
(** [set_notice state ~text ~warning] shows a notice in place of the legend. *)

val clear_notice : state -> state
(** [clear_notice state] drops any notice. *)

(** {1 Views} *)

val view :
  ?width:int ->
  ?height:int ->
  ?range:string ->
  ?on_click:(Spice_review.Cursor.t -> 'a) ->
  ?on_line_click:(Spice_review.Scope.t -> 'a) ->
  state ->
  Spice_review.t ->
  'a Mosaic.t
(** [view ?width ?height ?range ?on_click ?on_line_click state review] renders
    the screen: the top rule, the [Review  <range>] header with progress and
    verdict, the two-pane split (nav + diff, or a single focused pane below 80
    columns, or the key table when [state.help]), the bottom legend or notice,
    and the compose dialog floated over the dimmed panes when open. [on_click] /
    [on_line_click] report nav-row and diff-line selections. *)

val loading_view : ?width:int -> ?height:int -> unit -> _ Mosaic.t
(** [loading_view ()] is the rule + [Review  computing…] header held while the
    first snapshot loads, so the frame does not pop in. *)

val error_view :
  ?width:int -> ?height:int -> message:string -> unit -> _ Mosaic.t
(** [error_view ~message ()] is the rule + [Review] header + a [! message] error
    line + an [esc close] affordance (the load-failure state). *)
