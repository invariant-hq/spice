(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Anchors for edit-targeting workflows.

    An anchor names text observed by a read or search tool so later edit tools
    can refer to it. The deterministic source is only evidence for one observed
    path, line number, and text. A session can provide a stateful source that
    reconciles anchors across edits and line movement while keeping host tools
    on this interface. *)

type t
(** The type for model-visible edit anchors. Anchors are opaque evidence; use
    {!to_string} only when rendering them to a transcript or tool result. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same anchor. *)

val to_string : t -> string
(** [to_string t] is the model-visible anchor text. *)

val of_string : string -> t
(** [of_string s] is the anchor whose model-visible text is [s].

    Anchor sources backed by stateful resolvers mint anchors from their own
    vocabulary with this constructor. Anchors are still opaque evidence;
    construction does not validate any particular spelling.

    Raises [Invalid_argument] if [s] is empty. *)

module Source : sig
  (** Anchor source used by observation tools.

      A source receives the resolved workspace path, one-based line number, and
      exact observed line text. It may decline to emit an anchor for any line.
  *)

  type anchor := t

  type t
  (** The type for anchor sources. *)

  val make :
    (path:Spice_workspace.Path.t -> number:int -> text:string -> anchor option) ->
    t
  (** [make f] creates an anchor source from [f].

      [f] may close over session state. Returning [None] means no anchor should
      be emitted for that line. *)

  val none : t
  (** [none] never emits anchors. *)

  val deterministic : t
  (** [deterministic] emits stable content-derived anchors for observed lines.

      These anchors are not session-stable handles: if the file changes or the
      line moves, callers must re-observe or use a stateful source. *)

  val line :
    t ->
    path:Spice_workspace.Path.t ->
    number:int ->
    text:string ->
    anchor option
  (** [line t ~path ~number ~text] asks [t] for an anchor for one observed line.
  *)
end

module Resolver : sig
  (** Stateful anchor resolution for anchored edit tools.

      A resolver is caller-supplied state behind functions: it tracks the
      anchors a session has emitted for observed lines, reconciles them when
      file contents change, and resolves a model-provided anchor back to a
      current one-based line index. [spice.tools] defines only the interface;
      hosts own the state, its bounds, and its lifetime. *)

  (** The type for anchor resolution errors.

      [Not_found] means [anchor] does not currently name any tracked line of the
      file, including when the file was never observed or its anchors were
      invalidated. [Mismatch] means [anchor] names a line whose current text
      [expected] differs from the caller-supplied text [provided]. *)
  type error =
    | Not_found of { anchor : string }
    | Mismatch of { anchor : string; expected : string; provided : string }

  type t = {
    reconcile : path:Spice_workspace.Path.t -> lines:string list -> unit;
        (** [reconcile ~path ~lines] informs the resolver that [path]'s current
            logical lines are [lines]. Unchanged lines keep their anchors; new
            lines receive fresh ones. *)
    resolve :
      path:Spice_workspace.Path.t ->
      anchor:string ->
      expected:string ->
      (int, error) result;
        (** [resolve ~path ~anchor ~expected] is the one-based line index
            currently named by [anchor] in [path], provided the line's current
            text equals [expected]. *)
    source : Source.t;
        (** [source] is the read-side anchor view over the same state, for
            observation tools that render anchors. *)
  }
  (** The type for anchor resolvers. *)

  val error_equal : error -> error -> bool
  (** [error_equal a b] is [true] iff [a] and [b] are the same error. *)

  val error_message : error -> string
  (** [error_message e] is a model-facing diagnostic for [e]. It carries the
      expected and provided text for mismatches and tells the caller to re-read
      the file for current anchors. The exact text is not a stable matching
      surface. *)

  val pp_error : Format.formatter -> error -> unit
  (** [pp_error ppf e] formats [e] for diagnostics. *)
end
