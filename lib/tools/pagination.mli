(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Shared pagination vocabulary for the observer tools.

    The bounded-evidence tools ({!Glob}, {!Search_text}, and the line-range and
    directory-listing projections of {!Read_file}) all return a page of results
    plus a re-submittable continuation. This module names that shape once so the
    count precision, the completion status, and the [next:] continuation
    renderer are defined and tested in one place rather than copied per tool.

    A tool keeps its own [Input.t] as the ['req] continuation payload and its
    own result rows; it stores a {!Page.t} for the pagination bookkeeping. *)

(** {1:counts Counts} *)

module Count : sig
  (** Result-set size precision. *)

  type t =
    | Exact of int  (** The backend counted the full result set. *)
    | Lower_bound of int
        (** At least [n] results were seen before a bound stopped counting. *)
    | Unknown  (** The backend cannot report a count. *)
end

(** {1:pages Pages} *)

module Page : sig
  (** A page of bounded evidence with an optional continuation.

      ['req] is the tool's request type ({e i.e.} its [Input.t]); a partial page
      carries the continuation request that resumes after the returned rows. *)

  type 'req t

  val complete :
    returned:int -> total:Count.t -> offset:int -> limit:int -> 'req t
  (** [complete ~returned ~total ~offset ~limit] is a page that reached the end
      of the result set. [returned] is the number of rows in this page, [total]
      their counted precision, and [offset]/[limit] the one-based window that
      produced them. It has no continuation. *)

  val partial :
    returned:int ->
    total:Count.t ->
    offset:int ->
    limit:int ->
    next:'req option ->
    'req t
  (** [partial ~returned ~total ~offset ~limit ~next] is a usable but incomplete
      page. [next] is the continuation request that makes progress after this
      page, or [None] when no progress-making continuation exists. *)

  val returned : _ t -> int
  (** [returned t] is the number of rows in [t]. *)

  val total : _ t -> Count.t
  (** [total t] is the precision of the full result-set size. *)

  val offset : _ t -> int
  (** [offset t] is the one-based index of [t]'s first row. *)

  val limit : _ t -> int
  (** [limit t] is the row limit that produced [t]. *)

  val is_complete : _ t -> bool
  (** [is_complete t] is [true] iff [t] reached the end of the result set. It
      subsumes the per-tool [has_more] (which is its negation). *)

  val next : 'req t -> 'req option
  (** [next t] is the continuation request retained in [t], if any. It is always
      [None] for a {!complete} page. *)

  val hint :
    tool:string -> to_json:('req -> Jsont.json) -> 'req t -> string option
  (** [hint ~tool ~to_json t] is the model-visible continuation line for [t], or
      [None] when [t] has no continuation.

      The line is ["next: <tool> <json>"] where [<json>] is [to_json] of the
      continuation request encoded compactly. JSON string encoding escapes
      special path characters, so the escaping guarantee holds for every tool
      through this one renderer. The returned line has no trailing newline. *)
end
