(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Pure parser and exact text applier for apply-patch documents.

    [spice_patch] turns the model-facing [apply_patch] document format into
    typed operations over root-relative paths and applies parsed update chunks
    to caller-supplied file contents:

    {v
    *** Begin Patch
    *** Add File: path
    +new line
    *** Update File: path
    @@ optional context
    -old line
    +new line
    *** Delete File: path
    *** End Patch
    v}

    The module is filesystem-free: it validates patch syntax and path syntax,
    but does not read files, resolve workspaces, check permissions, detect path
    conflicts, render diffs, create directories, or mutate files. Host code
    should {!parse}, inspect the returned operations, resolve each
    {!Spice_path.Rel.t}, observe current file state, apply updates with
    {!Update.apply}, and lower the resulting complete-file changes to the edit
    layer.

    Operation, update, and chunk values are constructed only by {!parse}.
    Callers may inspect operations and chunks, but should keep update values as
    the units passed to {!Update.apply}. Matching is exact and deterministic. No
    fuzzy, whitespace, encoding, or line-ending normalization is performed
    beyond dropping a trailing carriage return from each patch document line
    during parsing. *)

(** {1:errors Parse Errors} *)

module Error : sig
  type t = private
    | Invalid_patch of { line : int option; message : string }
    | Invalid_hunk of { line : int; message : string }
    | Empty_patch of { line : int }
    | Empty_update of { line : int }
    | Invalid_path of { line : int; input : string; error : Spice_path.Error.t }
        (** Parse error.

            [Invalid_patch] reports malformed document boundaries or structure.
            [Invalid_hunk] reports an unrecognized or malformed operation hunk.
            [Empty_patch] reports a document with no operations. [Empty_update]
            reports an update operation or chunk without change lines.
            [Invalid_path] wraps the {!Spice_path.Rel} parser error for a hunk
            path.

            Line numbers are one-based in the original patch document after line
            splitting. [Invalid_patch.line] may be [None] for an end-of-input
            failure. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic. It names the one-based input
      line when [e] carries one, so the message is self-sufficient for UI, logs,
      and model-facing tool errors.

      Callers who need to branch on the failure should match [e]'s constructors
      rather than parse the message. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. It prints {!message}[ e]. *)
end

(** {1:updates Update Chunks} *)

module Update : sig
  type t
  (** Parsed update body.

      Values contain at least one chunk. Use {!chunks} for inspection and
      {!apply} to execute the update; a chunk list alone is not an update. *)

  module Error : sig
    type mismatch =
      | Missing_context of string
      | Missing_lines of { old_lines : string list; end_of_file : bool }
      | Missing_insertion_point of { end_of_file : bool }
          (** Update-application mismatch.

              [Missing_context line] means the exact context line was not found
              at or after the current search position. [Missing_lines] means
              the chunk's exact [old_lines] sequence was not found.
              [Missing_insertion_point] means an insertion-only chunk could not
              be placed. [end_of_file] records whether [*** End of File]
              constrained the failed match or insertion.
          *)

    type t
    (** Update-application error. *)

    val chunk : t -> int
    (** [chunk e] is the zero-based index of the first chunk that failed in the
        update passed to {!Update.apply}. *)

    val mismatch : t -> mismatch
    (** [mismatch e] is the exact application mismatch for [e]. *)

    val message : t -> string
    (** [message e] is a human-readable diagnostic. The wording is for UI,
        logs, and model-facing tool errors; callers should branch on
        {!mismatch} rather than parse the message. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats [e] for diagnostics. It prints {!message}[ e]. *)
  end

  type chunk = private {
    context : string option;
    old_lines : string list;
    new_lines : string list;
    end_of_file : bool;
  }
  (** Parsed update chunk.

      [context], when present, is the single line after [@@ ] that must be found
      before the replacement or insertion. [old_lines] is the exact sequence to
      replace and [new_lines] is the replacement sequence. A patch line prefixed
      with one space contributes its payload to both lists. If [old_lines] is
      empty, [new_lines] are inserted. [end_of_file] is set by
      [*** End of File].

      Chunks are produced only by {!parse}. A parsed update operation contains
      at least one chunk, and each chunk contains at least one old or new line.
  *)

  val chunks : t -> chunk list
  (** [chunks t] are [t]'s parsed chunks in document order.

      The returned list is non-empty. Chunk records are private, read-only views
      of parsed patch input; callers inspect them for diagnostics, permissions,
      and evidence, but apply the enclosing {!type:t}. *)

  val apply : t -> string -> (string, Error.t) result
  (** [apply update contents] applies [update] to [contents].

      Chunks apply in order to the evolving text and search from the position
      left by the previous successful chunk. [context = Some line] first matches
      [line] exactly at or after that position. Non-empty [old_lines] then
      replace the next exact occurrence of [old_lines]; when [end_of_file] is
      [true], the occurrence must be the file suffix.

      Empty [old_lines] insert [new_lines]. Without a context, insertion is at
      EOF. With a context, insertion is immediately after the matched context
      line; [end_of_file] also requires that context line to be the final line.

      Matching splits [contents] on [\n] and compares lines exactly. Carriage
      returns in [contents] are ordinary characters. [Ok text] preserves whether
      [contents] ended in [\n]; applying to an empty string therefore returns
      text without a final newline unless inserted text contains one. [Error e]
      identifies the first chunk that cannot be applied; callers retain the
      original [contents]. *)
end

(** {1:operations Operations} *)

module Operation : sig
  type t = private
    | Add of { path : Spice_path.Rel.t; contents : string }
    | Delete of { path : Spice_path.Rel.t }
    | Update of {
        path : Spice_path.Rel.t;
        move_to : Spice_path.Rel.t option;
        update : Update.t;
      }
        (** Parsed patch operation.

            [Add] carries the complete new file contents from [+] lines.
            [Delete] names a file to remove. [Update] names a file whose text
            should be transformed by [update]; [move_to], when present, is the
            destination path for the transformed contents.

            The parser does not check whether paths exist, whether an [Add]
            would overwrite an existing file, whether a [Delete] target is a
            file, or whether multiple operations name the same output path. *)

  val path : t -> Spice_path.Rel.t
  (** [path op] is the path in [op]'s hunk header.

      For moved updates, this is the source path, not the destination. *)

  val output_path : t -> Spice_path.Rel.t
  (** [output_path op] is the path that should contain the operation's resulting
      contents.

      For moved updates, this is the destination path. For [Add], [Delete], and
      non-moved [Update], this is {!path}[ op]. *)
end

(** {1:parsing Parsing} *)

val parse : string -> (Operation.t list, Error.t) result
(** [parse text] parses [text] as an apply-patch document.

    The result is the document's operations in order; it is non-empty. The
    document must start with [*** Begin Patch], end with [*** End Patch], and
    contain at least one operation. Leading and trailing whitespace around
    document boundary markers, operation headers, move headers, and
    [*** End of File] markers is ignored. A trailing [\r] at the end of each
    parsed patch line is discarded. Paths are parsed as {!Spice_path.Rel.t};
    absolute paths and paths that escape the root are rejected with
    {!Error.Invalid_path}.

    [*** Add File: path] must be followed by one or more consecutive [+] lines.
    Add contents always end in [\n]; use [++] for a content line whose first
    character is a literal plus. [*** Update File: path] may be followed by
    [*** Move to: path], then one or more chunks. The first update chunk may
    omit an [@@] context header, but later chunks must start with [@@] or
    [@@ context]. Empty lines between the update header, optional move header,
    and chunks are ignored; empty lines inside a chunk are invalid unless
    represented as context, removal, or insertion lines. [*** Delete File: path]
    has no body.

    [Error e] reports malformed patch syntax. Update-application mismatches are
    reported by {!Update.apply}, not by [parse]. *)
