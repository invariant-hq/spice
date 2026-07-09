(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The transcript document (01-transcript.md §Base grammar).

    Everything said and done, top to bottom: a stream of settled blocks. Blocks
    arrive already settled — there is no replay flag and no filtering pass, so a
    resumed history and a live turn render through this one path. The document
    owns the base grammar: one blank line between top-level blocks and none
    before the first, and the 2-column hanging gutters that align every body at
    column 2. *)

(** A settled block. Seams and every other watcher/echo/failure line are
    {!Notice.t} values, not their own block kinds. *)
type block =
  | Banner of Snapshot.t
      (** The session-start banner record (04-header-footer.md §Banner record):
          the frozen brand lockup and the session facts, rendered by
          {!Banner.record}. It heads the document as the first block the shell
          appends at the drop and scrolls away with the conversation — there is
          no sticky header. It carries its own framing margin, so {!view} adds
          no blank after it (the margin is that one blank, never doubled). *)
  | User of string
      (** A full-width [user]-background block: [❯ ] muted, text default, no
          markdown, wrapped lines hanging at column 2. *)
  | Assistant of string  (** [⏺] and prose markdown (see {!Prose.view}). *)
  | Reasoning of { duration_s : int; title : string option; body : string }
      (** Settled reasoning: the [∴ Thought for Ns · title] one-liner. [title]
          is omitted from the line when [None]; [body] is the all-muted markdown
          shown only when the view is expanded. *)
  | Tool of Tool_block.t
  | Notice of Notice.t

type t
(** A transcript document. *)

val empty : t
(** [empty] is the document with no blocks. *)

val is_fresh : t -> bool
(** [is_fresh t] is [true] when [t] holds nothing but the opening {!Banner}
    block (or nothing at all): the drop's pre-turn screen, before any settled
    content joins the banner. The shell reads it to place the blank before the
    live tail — a fresh document self-separates through the banner's own bottom
    margin, so no blank precedes the tail; a document carrying settled content
    below the banner is separated from the tail by the one-blank law. *)

val append : t -> block -> t
(** [append t block] is [t] with [block] added after its last block. Three
    last-block-only folding laws re-render in place rather than stack, and each
    fires only while the matching block is still last — separated by any other
    block, the incoming one appends fresh:

    - a {!Notice.Failure} whose [message] and [next_step] match the last block
      (also a failure) bumps that block's collapse count, dropping the incoming
      one's own count (01-transcript.md §Notices, failure class);
    - a same-source {!Notice.Data} replaces the previous data notice
      (01-transcript.md §Data notices);
    - a {!Tool} whose verb is {!Tool_block.Todo} — the todo board — replaces the
      previous board so two [todo_write]s in a row show one board (02-tools.md
      §Todo block).

    Every other block appends verbatim. *)

val user_block : string -> _ Mosaic.t
(** [user_block value] renders one {!User} block in isolation — the full-width
    user-background row (01-transcript.md §User message). The live tail reuses
    it to echo a submitted-but-not-yet-started prompt identically to its
    eventual settled document block. *)

val view : ?expanded:bool -> width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the document at [width] columns. [expanded] (default
    [false]) is the global lens: when [true], every reasoning block shows its
    body. Visibility is the caller's decision — the view never decides what to
    hide.

    Spacing follows the base grammar (01-transcript.md §Base grammar): one blank
    line between top-level blocks, none before the first. A {!Banner} block
    carries its own framing margin, so the blank that would follow it is dropped
    — the banner's margin is that one blank, never doubled.

    [width] flows to {!Banner.record}, which pre-truncates its facts to it in
    OCaml (Mosaic's [truncate:true] measures at the previous layout width —
    mosaic_flex_truncate_quirk). *)
