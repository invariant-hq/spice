(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Deterministic stateful implementation of {!Anchor.Resolver}.

    [Anchor_tracker] is the standard resolver behind {!Anchor.Resolver.t}: it
    tracks word-pair anchors for observed file lines, reconciles them across
    edits with a line-content-hash diff so unchanged lines keep their anchors,
    and resolves model-provided anchors back to current one-based line indexes.

    State is in-memory only and bounded: at most {!default_max_files} tracked
    files and {!default_max_lines} lines per file. Tracking a file past the file
    cap evicts the least-recently-used file; observing a file past the line cap
    untracks it. Either way the invalidated anchors resolve to the ordinary
    not-found error, whose message tells the model to re-read.

    Word-pair allocation is deterministic in the [seed] and the allocation
    order, so runs with scripted providers produce stable transcripts. Anchor
    words are file-scoped: the same word can name lines in two different files.
*)

type t
(** The type for anchor-tracking state. *)

val default_max_files : int
(** [default_max_files] is the default tracked-file cap, [1024]. *)

val default_max_lines : int
(** [default_max_lines] is the default per-file line cap, [50_000]. *)

val create : ?max_files:int -> ?max_lines:int -> seed:string -> unit -> t
(** [create ~seed ()] is empty tracker state.

    [seed] determines word-pair allocation; callers pass a session id so the
    anchors of a scripted run are reproducible. [max_files] defaults to
    {!default_max_files} and [max_lines] to {!default_max_lines}.

    Raises [Invalid_argument] if [max_files] or [max_lines] is not positive. *)

val resolver : t -> Anchor.Resolver.t
(** [resolver t] is the resolver view over [t].

    [reconcile] installs or diffs a file's current logical lines; [resolve] maps
    an anchor word plus expected line text to a one-based index; [source] is the
    read-side anchor view. The source assigns anchors while a file is observed
    from its first line in order (the shape of read renders) and answers lookups
    for other observations from the tracked state, declining when the observed
    line no longer matches. *)
