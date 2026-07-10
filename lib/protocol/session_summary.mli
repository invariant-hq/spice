(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Typed projection for listing saved sessions.

    A summary is the presentation-neutral row used by surfaces that list
    sessions. It keeps lifecycle and phase typed so callers can render, filter,
    or serialize without parsing display strings. Construct summaries with
    {!of_session}; use {!display_title} and {!search_key} for shared list
    behavior. *)

type t = {
  id : Spice_session.Id.t;  (** Session identifier. *)
  title : string option;
      (** Stored session title, if one has been derived or assigned. *)
  preview : string option;
      (** First non-empty user prompt preview, normalized for compact display,
          if the session contains one. *)
  lifecycle : Spice_session.Metadata.Status.t;
      (** Persisted lifecycle status. *)
  phase : Spice_session.State.Phase.t;  (** Current run phase. *)
  event_count : int;  (** Number of stored session events. *)
  turns : int;
      (** Number of accepted turns in the session, including an active
          unfinished turn. This is the conversational round-count a session
          list renders ("age · turns"), distinct from the finer-grained
          {!field:event_count}. Derived from {!Spice_session.State.turns}. *)
  active_turn : Spice_session.Turn.Id.t option;
      (** Active turn identifier, if the session is not idle. *)
  cwd : Spice_path.Abs.t;  (** Session working directory. *)
  forked_from : Spice_session.Metadata.Forked_from.t option;
      (** Fork origin recorded in session metadata, if any. *)
  created_at : Spice_session.Time.t;  (** Session creation time. *)
  updated_at : Spice_session.Time.t;  (** Last session update time. *)
  revision : Spice_session.Revision.t option;
      (** Store revision when the summary came from a persisted document; [None]
          for synthetic summaries. The revision token is store-owned; a client
          reads it but cannot mint one. *)
}
(** The type for one saved-session summary. Values are immutable snapshots; they
    do not track later store updates. *)

val of_session : ?revision:Spice_session.Revision.t -> Spice_session.t -> t
(** [of_session ?revision session] is the typed list projection for [session].
    [revision] populates {!field:revision}; omit it for synthetic rows. *)

val display_title : t -> string
(** [display_title t] is [t.title], or [t.id] when the session is untitled. *)

val search_key : t -> string
(** [search_key t] is a normalized text key suitable for list filtering. It
    includes the identifier, title, preview, and working directory when present.
*)
