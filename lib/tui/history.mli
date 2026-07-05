(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Prompt history: the JSONL codec, load semantics, and ctrl+r search.

    Spice persists submitted and discarded drafts to one global
    newline-delimited JSON file shared with the old TUI (`history.jsonl` next to
    the auth store). This module owns the on-disk record and the reverse-search
    surface; it is {b pure} — no file I/O and no locking. The runtime reads the
    file, appends under an F_LOCK, and decides where the file lives (the
    global-vs-per-workspace keying is deliberately not fixed here); it feeds
    this module the file contents and takes back encoded lines.

    {b Format compatibility is a hard constraint}: {!encode} and {!decode} use
    the same [composer.history_entry] schema the old TUI writes (schema_version
    1; a [session_id], [ts], and a [draft] of [text] plus optional [file_refs]
    and [pending_pastes]), so the two frontends never fork the file. Unknown or
    malformed lines are skipped on decode, never rejected.

    The arrow-walk over past prompts lives in {!Composer} (it holds the walk
    cursor and the initial-draft restore); this module supplies the loaded
    entries it walks and the ctrl+r {!Search} that runs beside it. *)

(** {1:entries Entries} *)

module Entry : sig
  type t
  (** The type for one prompt-history record: a submitted or discarded
      {!Draft.History_entry.t} with the session it belongs to and its Unix
      timestamp. *)

  val of_draft :
    session:Spice_session.Id.t -> ts:int -> Draft.History_entry.t -> t option
  (** [of_draft ~session ~ts entry] is the record to persist for [entry], or
      [None] when its text is blank after trimming (nothing is stored for an
      empty prompt). The stored text is trimmed; if trimming changed it the
      structured metadata is dropped (its spans no longer align), matching the
      old writer. [ts] is supplied by the runtime (this module reads no clock).
  *)

  val session : t -> Spice_session.Id.t
  (** [session t] is the session [t] was submitted in. *)

  val draft : t -> Draft.History_entry.t
  (** [draft t] is [t]'s stored draft, for restoring into the composer. *)

  val text : t -> string
  (** [text t] is [t]'s visible prompt text ([Draft.History_entry.text]). *)
end

(** {1:codec Codec} *)

val encode : Entry.t -> string
(** [encode e] is [e] as one [composer.history_entry] JSON object {e without} a
    trailing newline — the runtime appends the [\n] as it writes the line. The
    bytes match the old TUI's writer.

    Raises [Invalid_argument] only on an internal encoder failure, which does
    not occur for a well-formed entry. *)

val decode : string -> Entry.t option
(** [decode line] is the entry [line] encodes, or [None] when [line] is blank,
    malformed JSON, not a [composer.history_entry], or carries empty text.
    Unknown object fields are ignored. *)

val load : string -> Entry.t list
(** [load contents] decodes every line of a [history.jsonl] [contents], newest
    first, capped at the most recent 200 records. Malformed lines are skipped.
    Entries are {e not} deduplicated — {!Search} and {!Composer} dedupe for
    their own surfaces. Map with {!Entry.draft} to feed
    {!Composer.with_history}. *)

(** {1:search Ctrl+r search} *)

module Search : sig
  type t
  (** The type for the ctrl+r reverse-search state: the query and the selection
      over the ranked matches (05-overlays-pickers.md §Prompt-history search).
  *)

  val make : ?current:Spice_session.Id.t -> entries:Entry.t list -> unit -> t
  (** [make ~entries ()] opens a search over [entries] (newest first, as from
      {!load}), ranking records from the [current] session above earlier ones.
      Records with identical text are collapsed, keeping the most recent.
      [current] is omitted before the load has attributed a session — nothing
      ranks as current then, which is the truth of that moment; ctrl+r never
      waits on the load. *)

  val refresh : ?current:Spice_session.Id.t -> entries:Entry.t list -> t -> t
  (** [refresh ~entries t] swaps in freshly loaded records (and the [current]
      attribution) while the search is open — a load landing after ctrl+r. The
      query stands and the selection clamps. *)

  val with_query : string -> t -> t
  (** [with_query q t] refilters for query [q] by fuzzy subsequence match
      (case-insensitive; the query's characters appear in order, not necessarily
      adjacent). The selection resets to the first row when [q] changes and
      otherwise clamps. *)

  val selected_entry : t -> Draft.History_entry.t option
  (** [selected_entry t] is the highlighted record's draft, or [None] when
      nothing matches. On [↵] the shell restores it into the composer
      ([Composer.Restore_history]) — a ctrl+r pick {e inserts}, never submits
      (03-ia-screens-overlays.md §Completions). *)

  val move : [ `Up | `Down ] -> t -> t
  (** [move dir t] moves the selection one row, wrapping at the ends. With no
      matches [t] is unchanged. *)

  val view : width:int -> t -> _ Mosaic.t
  (** [view ~width t] renders the [reverse-i-search: <query>] header and the
      matching rows through {!Completion_list}: each row is the first line of a
      past prompt, tail-truncated to [width], the selection in [accent]. Empty
      states are {!Completion_list.note} ["no prompt history"] (nothing stored)
      or ["no matching prompts"] (nothing matches the query). *)
end
