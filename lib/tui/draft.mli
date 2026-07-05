(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structured composer drafts.

    A draft is the composer input buffer plus the structured payloads plain text
    cannot carry safely. The visible text is what the composer renders, but byte
    ranges may mark atomic elements — file references and large-paste
    placeholders — that edit and delete as a unit.

    This module is pure and carries no Mosaic types: it owns the text algebra
    (span edits, paste collapse, [@]-token detection, prompt-history snapshots)
    and hands the composer a plain styled-run projection ({!runs}) to feed the
    textarea.

    The intended flow is:

    - construct with {!empty}, {!of_text}, or {!of_history_entry};
    - update with {!insert_text}, {!replace_range}, {!replace_visible_text},
      {!insert_file_ref}, {!replace_active_file_ref_token}, and {!insert_paste};
    - project for rendering with {!text}, {!cursor}, and {!runs};
    - submit with {!submit}, which expands paste placeholders and returns a
      structured history entry. *)

(** {1:spans Spans} *)

module Span : sig
  type t
  (** The type for half-open byte ranges \[[first];[last]\) in draft text.
      Values satisfy [0 <= first <= last]. *)

  val make : first:int -> last:int -> t
  (** [make ~first ~last] is the span \[[first];[last]\).

      Raises [Invalid_argument] if [first < 0] or [last < first]. *)

  val cursor : int -> t
  (** [cursor pos] is the empty span at [pos]. *)

  val first : t -> int
  (** [first t] is [t]'s first byte offset. *)

  val last : t -> int
  (** [last t] is [t]'s exclusive last byte offset. *)

  val length : t -> int
  (** [length t] is [last t - first t]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same bounds. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for debugging. *)
end

(** {1:file_refs File References} *)

module File_ref : sig
  type t
  (** The type for a file reference carried by the draft. *)

  val make : ?label:string -> string -> t
  (** [make ?label path] is a file reference to [path]. [label] defaults to
      [path] and is the visible text inserted in the draft.

      Raises [Invalid_argument] if [path] or the resulting label is empty. *)

  val path : t -> string
  (** [path t] is the referenced path. *)

  val label : t -> string
  (** [label t] is the visible text for [t]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same path and label. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for debugging. *)
end

(** {1:elements Structured Elements} *)

(** The type for structured draft elements. *)
type element =
  | File_ref of File_ref.t
      (** An atomic file reference visible as {!File_ref.label}. *)
  | Paste_placeholder of string
      (** A visible placeholder for a large paste payload. *)

type range = { span : Span.t; element : element }
(** A structured element bound to a span of the visible draft text. *)

type pending_paste = { paste_placeholder : string; paste_text : string }
(** A large paste payload not currently expanded in visible text. *)

(** {1:history History Entries} *)

module History_entry : sig
  type t
  (** The type for draft state stored in prompt history. *)

  val make :
    ?file_refs:(Span.t * File_ref.t) list ->
    ?pending_pastes:pending_paste list ->
    string ->
    t
  (** [make ?file_refs ?pending_pastes text] is a history entry whose visible
      text is [text]. [file_refs] and [pending_pastes] default to [[]]. *)

  val of_text : string -> t
  (** [of_text text] is [make text]. *)

  val text : t -> string
  (** [text t] is [t]'s visible text. *)

  val file_refs : t -> (Span.t * File_ref.t) list
  (** [file_refs t] is every file reference carried by [t], in stored order. *)

  val pending_pastes : t -> pending_paste list
  (** [pending_pastes t] is every unexpanded large-paste payload carried by [t],
      in stored order. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same visible text,
      file-reference metadata, and pending paste payloads. *)
end

(** {1:drafts Drafts} *)

type t
(** The type for composer drafts.

    The cursor is a byte offset in {!text}. Ranges are kept consistent with text
    edits; editing through an atomic range removes the corresponding element
    rather than leaving a stale payload. *)

type submitted = {
  submitted_text : string;
      (** Text submitted to the model after trimming and paste expansion. *)
  submitted_history_entry : History_entry.t;
      (** Structured entry suitable for prompt history. *)
}
(** The type for a non-empty submitted draft. *)

val large_paste_char_threshold : int
(** [large_paste_char_threshold] is the default number of Unicode scalar values
    above which {!insert_paste} inserts a placeholder instead of visible paste
    text. *)

val large_paste_line_threshold : int
(** [large_paste_line_threshold] is the default number of lines (one trailing
    newline not counted) at which {!insert_paste} inserts a placeholder instead
    of visible paste text. *)

val empty : t
(** [empty] is the empty draft with cursor at byte offset [0]. *)

val of_text : string -> t
(** [of_text text] is a plain-text draft with cursor at the end of [text]. *)

val text : t -> string
(** [text t] is the visible draft text. *)

val cursor : t -> int
(** [cursor t] is [t]'s cursor byte offset. *)

val ranges : t -> range list
(** [ranges t] is [t]'s structured ranges. *)

val pending_pastes : t -> pending_paste list
(** [pending_pastes t] is [t]'s unexpanded large-paste payloads. *)

val is_blank : t -> bool
(** [is_blank t] is [true] iff {!text} is empty or all whitespace, i.e. exactly
    when {!submit} would return [None]. *)

val with_cursor : int -> t -> t
(** [with_cursor pos t] is [t] with cursor at [pos].

    Raises [Invalid_argument] if [pos] is outside {!text} or not on a UTF-8
    character boundary. *)

val replace_range : Span.t -> string -> t -> t
(** [replace_range span replacement t] replaces [span] in [t]'s visible text.

    If [span] intersects an atomic range, the replacement expands to cover the
    entire atomic range. Ranges after the replacement are shifted. Ranges
    touched by the replacement are removed. The cursor moves to the end of the
    inserted [replacement].

    Raises [Invalid_argument] if [span] is outside {!text} or not aligned to
    UTF-8 character boundaries. *)

val replace_visible_text : string -> t -> t
(** [replace_visible_text text t] adapts [t] to a full replacement of its
    visible text, as emitted by textarea widgets that report only the new value.

    The replacement is interpreted as one contiguous edit between the common
    prefix and suffix of the old and new visible text. Structured ranges outside
    that edit are preserved and shifted; ranges touched by the edit follow
    {!replace_range} atomic-replacement semantics. The cursor is placed at the
    end of the inferred edit. If [text] is unchanged, [t] is returned unchanged.
*)

val insert_text : string -> t -> t
(** [insert_text text t] inserts [text] at {!cursor}. *)

val insert_file_ref : ?label:string -> path:string -> t -> t
(** [insert_file_ref ?label ~path t] inserts an atomic file reference at
    {!cursor}. The visible insertion is the file reference label. *)

val active_file_ref_token_span : t -> Span.t option
(** [active_file_ref_token_span t] is the [@]-prefixed token containing
    {!cursor}, if any: the nearest [@] before the cursor with no whitespace
    between, mid-draft as well as at draft start. Tokens are delimited by ASCII
    whitespace. *)

val replace_active_file_ref_token : ?label:string -> path:string -> t -> t
(** [replace_active_file_ref_token ?label ~path t] replaces the active
    [@]-prefixed token with an atomic file reference. If there is no active
    token, the file reference is inserted at {!cursor}. *)

val insert_paste :
  ?char_threshold:int -> ?line_threshold:int -> string -> t -> t
(** [insert_paste pasted t] inserts [pasted] at {!cursor}.

    Carriage-return line endings are normalized to [\n]. If the paste reaches
    either threshold, an atomic [[Pasted text #N +M lines]] placeholder is
    inserted and the full text is kept in {!pending_pastes}; [N] is unique
    within [t] (scanning both the visible text and pending payloads, so a
    history-restored chunk never collides) and shares the [[Image #N]]
    namespace, [M] is the paste's newline count and is omitted when zero.
    [char_threshold] defaults to {!large_paste_char_threshold} and
    [line_threshold] to {!large_paste_line_threshold}. *)

val expand_paste_placeholders : t -> t
(** [expand_paste_placeholders t] replaces any known paste placeholders in [t]
    with their full paste text and removes the consumed pending payloads.
    Unknown placeholders are left as literal visible text. *)

(** {1:rendering Styled-run projection} *)

(** The style class of a run of visible draft text. *)
type run_kind =
  | Plain  (** Ordinary editable text. *)
  | Atom
      (** An atomic element — a file reference or a paste placeholder — rendered
          in the app-owned token color. *)

val runs : t -> (Span.t * run_kind) list
(** [runs t] partitions {!text} into consecutive styled runs, ascending: each is
    a maximal span of [Plain] editable text or an [Atom] element. The
    concatenation of the run substrings is exactly {!text}, so the composer can
    feed them to the textarea as styled spans. *)

(** {1:history_io Prompt history} *)

val history_entry : t -> History_entry.t
(** [history_entry t] is [t] as a structured prompt-history value. *)

val of_history_entry : History_entry.t -> t
(** [of_history_entry entry] is [entry] restored as an editable draft with
    cursor at the end of its visible text.

    Structured metadata whose span no longer matches the visible text is
    ignored. *)

val submit : t -> (submitted * t) option
(** [submit t] is [Some (submitted, empty)] if [t] contains non-blank text after
    paste expansion and trimming, and [None] otherwise. *)
