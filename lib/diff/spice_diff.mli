(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Unified diffs for in-memory text states.

    A {!File_change.t} is one labeled file creation, deletion, or modification.
    {!render} formats changes as unified diff text and returns structured
    {!stats}; {!stats_of_changes} computes unconstrained statistics without
    rendering.

    Contents are caller-supplied strings interpreted as line-oriented text. The
    module does not read files, validate encodings, detect binary data, or make
    the rendered output an authority-bearing patch. Keep the source edit or
    workspace observation when later code needs to apply or prove a change.

    Use {!Label.escaped} for arbitrary labels. Use {!Label.of_string} only for
    labels that already satisfy the unified diff header constraints.

    Unbounded rendering, hunking, and statistics are exact and may perform
    unbounded line-diff work. Pass {!Limits.t} to {!render}, or
    [max_edit_distance] to {!hunks}, when input text is large, untrusted, or
    model-controlled. *)

(** {1:labels Labels} *)

module Label : sig
  type t
  (** The type for file labels in rendered diffs.

      Labels appear after [---] and [+++] in file headers. They are display
      text, not filesystem paths. Values are non-empty and contain no newline,
      carriage return, or NUL byte. *)

  val of_string : string -> t
  (** [of_string label] is trusted diff header label [label].

      Raises [Invalid_argument] if [label] is empty or contains a newline,
      carriage return, or NUL byte. Use {!escaped} for arbitrary display text.

      This checks only diff header structure. It does not make [label] safe for
      terminals, logs, or prompts; use {!render} in [`Display] mode for display
      escaping. *)

  val escaped : string -> t
  (** [escaped label] is a valid label for arbitrary display text [label].

      Invalid header characters and other non-printing bytes are escaped. The
      empty string becomes ["<empty>"]. The returned label can be passed through
      {!to_string} and accepted again by {!of_string}. *)

  val to_string : t -> string
  (** [to_string label] is [label]'s display text. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same display text. *)

  val compare : t -> t -> int
  (** [compare a b] orders labels by display text. The order is compatible with
      {!equal}. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf label] formats [label] as display text. *)
end

(** {1:file_changes File changes} *)

module File_change : sig
  type t
  (** The type for one file's text state transition.

      A value carries a label and at least one text state. It is a creation,
      deletion, or modification, never the absent-to-absent state. *)

  val of_states :
    label:Label.t -> before:string option -> after:string option -> t option
  (** [of_states ~label ~before ~after] is the change from [before] to [after].

      [before = None] means file creation. [after = None] means file deletion.
      If both states are [None], this is [None].

      Equal [before] and [after] contents produce a no-op modification value.
      Rendering and statistics omit no-op modifications. Creations and deletions
      count as file changes even when their contents are empty. *)

  val create : label:Label.t -> contents:string -> t
  (** [create ~label ~contents] is a file creation. *)

  val delete : label:Label.t -> contents:string -> t
  (** [delete ~label ~contents] is a file deletion. *)

  val modify : label:Label.t -> before:string -> after:string -> t
  (** [modify ~label ~before ~after] is a file modification.

      Equal [before] and [after] contents are valid and are omitted by rendering
      and statistics. *)

  val label : t -> Label.t
  (** [label change] is [change]'s diff label. *)

  val before : t -> string option
  (** [before change] is [change]'s before contents, if any. *)

  val after : t -> string option
  (** [after change] is [change]'s after contents, if any. *)
end

(** {1:statistics Statistics} *)

type stats = private { files : int; additions : int; deletions : int }
(** The type for structured diff statistics.

    Fields are non-negative. [files] counts non-noop file changes. [additions]
    and [deletions] count inserted and removed text lines; a non-empty final
    segment without a newline counts as a line, and newline presence is part of
    line identity. They do not count bytes, display columns, or changed
    filesystem objects.

    When {!render} omits file content because [limits] were exceeded, [files]
    still counts the omitted file changes and [additions] and [deletions] do not
    include omitted lines. *)

val stats_v : files:int -> additions:int -> deletions:int -> stats
(** [stats_v ~files ~additions ~deletions] is a {!stats} carrying counts
    computed outside this module, such as those parsed from
    [git diff --numstat]. Use it when the diff engine is not this module's and
    only the counts are wanted; {!render} and {!stats_of_changes} are the
    in-module producers.

    Raises [Invalid_argument] if any argument is negative. *)

(** {1:hunks Structured hunks} *)

module Hunk : sig
  (** Structured change regions computed from two text states.

      Values are produced by {!Spice_diff.hunks}. A hunk is one contiguous
      change region with its surrounding context lines. Hunks whose context
      ranges touch or overlap are merged, matching {!render}'s grouping. *)

  module Line : sig
    (** The type for line roles within a hunk. Removals precede additions within
        each change block, matching {!Hunk.lines} and rendered output. *)
    type kind =
      | Context  (** An unchanged line present in both text states. *)
      | Added  (** A line present only in the after text. *)
      | Removed  (** A line present only in the before text. *)

    type t
    (** The type for one hunk line. *)

    val kind : t -> kind
    (** [kind line] is [line]'s role. *)

    val text : t -> string
    (** [text line] is [line]'s content without its terminating newline. *)

    val newline : t -> bool
    (** [newline line] is [true] iff [line] is terminated by a newline in its
        source text. Newline presence is part of line identity: a final segment
        without a newline never equals the same content with one. *)

    val old_line : t -> int option
    (** [old_line line] is [line]'s 1-based line number in the before text. This
        is [None] iff {!kind} is [Added]. *)

    val new_line : t -> int option
    (** [new_line line] is [line]'s 1-based line number in the after text. This
        is [None] iff {!kind} is [Removed]. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf line] formats [line] as a raw structural hunk line: a [' '],
        ['-'], or ['+'] prefix followed by the unescaped content. It does not
        append a line terminator or missing-final-newline marker. Use {!render}
        for prompt, log, terminal, or patch-like display text. *)
  end

  type t
  (** The type for one contiguous change region with surrounding context. *)

  val old_start : t -> int
  (** [old_start hunk] is the 1-based first before-text line covered by [hunk].
      When {!old_count} is [0] the hunk inserts lines and [old_start] is the
      before-text position the insertion precedes. *)

  val old_count : t -> int
  (** [old_count hunk] is the number of before-text lines covered by [hunk]. *)

  val new_start : t -> int
  (** [new_start hunk] is the 1-based first after-text line covered by [hunk].
      When {!new_count} is [0] the hunk only removes lines and [new_start] is
      the after-text position following the removal. *)

  val new_count : t -> int
  (** [new_count hunk] is the number of after-text lines covered by [hunk]. *)

  val lines : t -> Line.t list
  (** [lines hunk] is [hunk]'s lines in unified diff order: context interleaved
      with change blocks, removals before additions within each block. Within
      each side, source order is preserved. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] cover the same ranges with equal
      lines. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf hunk] formats [hunk] as raw structural hunk text: the [@@] header
      followed by one line per {!Line.t}. Content is not display-escaped and
      missing final newlines are not marked. Use {!render} for prompt, log,
      terminal, or patch-like display text. *)
end

val hunks :
  ?context:int ->
  ?max_edit_distance:int ->
  before:string ->
  after:string ->
  unit ->
  Hunk.t list option
(** [hunks ~before ~after ()] is the line diff of the two texts grouped into
    context-separated hunks.

    [context] is the number of unchanged lines kept around each change region
    and defaults to [3]. The result is computed with the same line splitting,
    edit engine, and hunk grouping as {!render}, so hunk ranges agree with
    rendered [@@] headers for the same inputs.

    Equal texts are [Some []]. The result is [None] iff [max_edit_distance] is
    provided and the Myers edit distance between the texts exceeds it. Without
    [max_edit_distance], hunk computation is exact and may perform unbounded
    diff work.

    Raises [Invalid_argument] if [context] or [max_edit_distance] is negative.
*)

(** {1:limits Limits} *)

module Limits : sig
  type t
  (** The type for display rendering limits.

      Values bound rendered display output and diff computation. All integer
      limits are non-negative. *)

  val make :
    max_files:int ->
    max_file_bytes:int ->
    max_lines:int ->
    ?max_edit_distance:int ->
    unit ->
    t
  (** [make ~max_files ~max_file_bytes ~max_lines ?max_edit_distance ()] is a
      display limit set.

      [max_files] bounds the number of non-noop file entries rendered before a
      remaining-file summary is emitted. [max_file_bytes] and [max_lines] bound
      each file by the larger of its before and after states.
      [max_edit_distance], when provided, bounds the Myers edit distance
      searched for one file. Files exceeding a byte, line, or edit-distance
      limit render only headers and an omission note.

      Raises [Invalid_argument] if any supplied limit is negative. *)
end

(** {1:rendering Rendering} *)

type render_mode = [ `Display | `Raw ]
(** The type for rendered text policy.

    [`Display] preserves printable UTF-8, escapes control and
    bidirectional-formatting characters, and hexadecimal-escapes malformed
    UTF-8 bytes in labels and content for prompts, logs, and terminals. Its
    output is valid UTF-8. [`Raw] writes label and content bytes without display
    escaping; the renderer still inserts diff syntax, line prefixes, and
    missing-newline markers. Neither mode turns the output into an
    authority-bearing patch format. *)

type t
(** The type for rendered unified diff text and its structured statistics.

    Values are produced by {!render}. Inspect the text with {!to_string} and the
    structured counts with {!stats}. *)

val render :
  ?mode:render_mode ->
  ?limits:Limits.t ->
  ?context:int ->
  File_change.t list ->
  t
(** [render changes] is a unified diff for [changes].

    [context] is the number of unchanged lines around each hunk and defaults to
    [3]. [mode] defaults to [`Display]. File entries are rendered in input
    order. No-op modifications are omitted. Creations and deletions use
    [/dev/null] on the absent side. Empty creations and deletions render file
    headers without hunks. Missing final newlines render the standard unified
    diff marker.

    When [limits] are exceeded, affected file content is represented by
    display-only omission notes instead of full hunks. The returned {!stats}
    still counts omitted files but does not include omitted additions or
    deletions. Without [limits], rendering is exact and may perform unbounded
    diff work.

    Raises [Invalid_argument] if [context] is negative. *)

val stats : t -> stats
(** [stats diff] is [diff]'s structured statistics. *)

val omitted : t -> int
(** [omitted diff] is the number of file changes whose content [render] elided
    because a display or edit-distance limit was exceeded. These files are
    counted in [(stats diff).files] but contribute no additions or deletions.
    [omitted diff] is [0] when [render] was called without limits, in which case
    [(stats diff)] is exact and equal to [stats_of_changes] of the same changes.
*)

val stats_of_changes : File_change.t list -> stats
(** [stats_of_changes changes] is the structured statistics for [changes]
    without rendering unified text. No-op modifications are omitted. The result
    is exact and may perform unbounded diff work for modifications.

    With no rendering limits, [stats_of_changes changes] is equal to
    [stats (render changes)]. Use {!render} when display limits must affect
    reported statistics. *)

val to_string : t -> string
(** [to_string diff] is [diff]'s rendered unified diff text. *)

val is_empty : t -> bool
(** [is_empty diff] is [true] iff [stats diff].files is [0]. *)
