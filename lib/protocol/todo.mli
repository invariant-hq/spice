(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Session-local todos.

    Todos are host product state for progress rendering. They are not
    {!Spice_session} transcript state and should not be reconstructed from
    assistant prose.

    The model-facing tool replaces the whole checked list for a session in one
    call; this module satisfies {!Call.HOST_TOOL} with {!type:t} — the
    replacement list — as its request. Host code composes {!Item.t} values into
    a checked list with {!make}. Construction reports invariant failures as
    diagnostic strings. *)

module Id : sig
  (** Non-empty stable todo identifiers. *)

  type t
  (** The type for todo identifiers. The string form is the JSON value and is
      used for equality and ordering. *)

  val of_string : string -> (t, string) result
  (** [of_string s] is [s] as a todo id. Errors when [s] is empty. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same id. *)

  val compare : t -> t -> int
  (** [compare a b] orders ids by their stable string representation. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps todo ids to JSON strings, funneling through {!of_string}. *)
end

module Owner : sig
  (** Todo ownership within a session-local list. *)

  type t
  (** The type for a todo owner. Owners are non-empty stable strings such as
      ["main"] or a child session id. *)

  val main : t
  (** [main] is the root-session owner. *)

  val of_string : string -> (t, string) result
  (** [of_string s] is [s] as a todo owner. Errors when [s] is empty. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable string representation. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same owner. *)

  val compare : t -> t -> int
  (** [compare a b] orders owners by their stable string representation. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps owners to JSON strings, funneling through {!of_string}. *)
end

module Status : sig
  (** Todo lifecycle status.

      Statuses are row state; list-level validation enforces that each owner has
      at most one {!In_progress} item. *)

  type t =
    | Pending
    | In_progress
    | Completed
    | Cancelled  (** The type for todo lifecycle status. *)

  val of_string : string -> t option
  (** [of_string s] parses [s] as a status, [None] for unknown spellings. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same status. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps statuses to JSON strings. *)
end

module Priority : sig
  (** Todo priority. *)

  type t = High | Medium | Low  (** The type for todo priority. *)

  val default : t
  (** [default] is {!Medium}. *)

  val of_string : string -> t option
  (** [of_string s] parses [s] as a priority, [None] for unknown spellings. *)

  val to_string : t -> string
  (** [to_string t] is [t]'s stable spelling. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same priority. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps priorities to JSON strings. *)
end

module Item : sig
  (** Todo items. *)

  type t = private {
    id : Id.t;
    owner : Owner.t;
    content : string;
    status : Status.t;
    priority : Priority.t;
    position : int;
  }
  (** The type for one todo row. [content] is non-empty and [position] is
      non-negative; per-list contiguity is checked by {!make}. *)

  val make :
    id:Id.t ->
    ?owner:Owner.t ->
    content:string ->
    ?status:Status.t ->
    ?priority:Priority.t ->
    position:int ->
    unit ->
    (t, string) result
  (** [make ~id ?owner ~content ?status ?priority ~position ()] is a todo item.

      [owner] defaults to {!Owner.main}, [status] to {!Status.Pending},
      [priority] to {!Priority.default}. Errors when [content] is empty or
      [position] is negative. *)

  val id : t -> Id.t
  (** [id t] is [t]'s id. *)

  val owner : t -> Owner.t
  (** [owner t] is [t]'s owner. *)

  val content : t -> string
  (** [content t] is [t]'s human-readable task text. *)

  val status : t -> Status.t
  (** [status t] is [t]'s lifecycle status. *)

  val priority : t -> Priority.t
  (** [priority t] is [t]'s priority. *)

  val position : t -> int
  (** [position t] is [t]'s zero-based position within its owner list. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same item. *)

  val pp : Format.formatter -> t -> unit
  (** [pp] formats [t] for diagnostics. *)

  val jsont : t Jsont.t
  (** [jsont] maps items to JSON objects, funneling through {!make}. *)
end

type t
(** The type for a checked session-local todo list.

    Invariants: ids are unique; positions are contiguous from zero within each
    owner; each owner has at most one {!Status.In_progress} item. Values from
    {!make} and {!decode} are sorted by owner and position. *)

val empty : t
(** [empty] has no todos. *)

val make : Item.t list -> (t, string) result
(** [make items] is a checked list sorted by owner and position. Errors on
    duplicate ids, non-contiguous positions, or two in-progress items for one
    owner. This is the single validation path; {!jsont} and {!decode} funnel
    through it. *)

val items : t -> Item.t list
(** [items t] are all todos in checked storage order. *)

val by_owner : Owner.t -> t -> Item.t list
(** [by_owner owner t] are [owner]'s todos ordered by position. *)

val counts : ?owner:Owner.t -> t -> (Status.t * int) list
(** [counts ?owner t] counts todos by status in {!Status.Pending},
    {!Status.In_progress}, {!Status.Completed}, {!Status.Cancelled} order,
    including zero counts. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] contain the same items. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [t] for diagnostics. *)

val jsont : t Jsont.t
(** [jsont] maps todo lists to JSON arrays, funneling through {!make}. *)

(** {1:host_tool Host tool} *)

val name : string
(** [name] is the model-visible todo update tool name. *)

val tool : Spice_llm.Tool.t
(** [tool] is the model-visible todo update tool declaration. *)

val decode : Spice_llm.Tool.Call.t -> (t, string) result
(** [decode call] decodes [call]'s input as a replacement todo list. Errors with
    a diagnostic when [call] does not target {!name} or its payload fails shape
    or list validation. *)
