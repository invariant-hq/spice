(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Portable, normalized lexical path syntax.

    A path is slash-separated text after lexical normalization. {!Rel.t} is
    rooted at an implicit caller-owned root; {!Abs.t} is rooted at [/]. Both
    forms reject malformed components at construction time.

    Values are pure syntax: they do not inspect the filesystem, resolve
    symlinks, consult a current directory, name a host authority, or prove
    workspace containment. Resolve those properties in the workspace or
    host-specific layer that owns them.

    Parse raw input with the result-returning parsers, then keep the narrower
    kind in the type. Code that has not yet chosen a kind calls {!Rel.of_string}
    or {!Abs.of_string} directly. Compose typed values with {!Rel.append},
    {!Rel.resolve}, {!Abs.append_rel}, {!Abs.resolve}, and {!Abs.resolve_any}.
*)

(** {1:errors Errors} *)

module Error : sig
  (** Structured path syntax errors.

      Match constructors for recovery. {!message} and {!pp} are human-facing
      diagnostics; their wording is not a stable interface. *)
  type t =
    | Empty  (** The input path is empty where empty input is not accepted. *)
    | Relative  (** Slash-rooted absolute syntax was expected. *)
    | Absolute  (** Root-relative syntax was expected. *)
    | Escapes_root
        (** Relative resolution of [..] would move above the implicit root. *)
    | Malformed_component of string
        (** [Malformed_component component] carries the rejected component.
            Components are invalid if they are empty, [.], [..], contain [/],
            backslash, or NUL, or start with an ASCII-letter drive prefix such
            as [C:]. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      [message] is for display, not programmatic matching. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same path syntax error. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

(** {1:rel Relative paths} *)

module Rel : sig
  type t
  (** The type for normalized root-relative lexical paths.

      {!root} is the empty path below an implicit root and renders as ["."];
      non-root values are non-empty component lists separated by [/]. Components
      are never empty, [.], [..], contain [/], backslash, NUL, or start with an
      ASCII-letter drive prefix.

      A [Rel.t] is not a filesystem confinement proof. *)

  val root : t
  (** [root] is the empty path below the implicit root. *)

  val is_root : t -> bool
  (** [is_root path] is [true] iff [path] is {!root}. *)

  val of_string : string -> (t, Error.t) result
  (** [of_string path] parses and normalizes root-relative [path].

      Normalization removes [.] components, collapses repeated [/] separators,
      and resolves [..] against preceding components. The root spelling is
      ["."], not [""]. Errors are:
      - {!Error.Empty} if it is [""];
      - {!Error.Absolute} if it starts with [/], a backslash, or a drive prefix;
      - {!Error.Escapes_root} if [..] would move above {!root};
      - {!Error.Malformed_component} if a remaining component is malformed.

      [/] is the only separator. Backslash and drive prefixes are rejected, not
      interpreted as native syntax. Empty string root encodings belong to the
      boundary format that owns them. *)

  val of_string_exn : string -> t
  (** [of_string_exn path] is {!of_string}[ path].

      Raises [Invalid_argument] if [path] is invalid. Use this for trusted
      source-code literals; use {!of_string} at input boundaries. *)

  val to_string : t -> string
  (** [to_string path] is [path]'s normalized string form. {!root} is ["."]. *)

  val components : t -> string list
  (** [components path] are [path]'s components. {!root} has no components. *)

  val is_component : string -> bool
  (** [is_component component] is [true] iff [component] is non-empty, not [.]
      or [..], contains no [/], backslash, or NUL, and does not start with an
      ASCII-letter drive prefix. *)

  val add_component : t -> string -> (t, Error.t) result
  (** [add_component path component] is [Ok p] where [p] is [path] followed by
      [component], or [Error e] if [component] is malformed.

      [component] must satisfy {!is_component}. *)

  val append : t -> t -> t
  (** [append a b] appends [b] below [a]. {!root} is identity on either side. *)

  val resolve : t -> string -> (t, Error.t) result
  (** [resolve root path] parses [path] as relative syntax below [root].

      The syntax is the same as {!of_string}, except [..] is resolved against
      [root]. Errors include {!Error.Empty} for [""], {!Error.Absolute} for
      slash-rooted, backslash-rooted, or drive-prefixed input,
      {!Error.Escapes_root} if [..] would move above {!root}, and
      {!Error.Malformed_component} for malformed components. *)

  val parent : t -> t option
  (** [parent path] is [Some parent] if [path] is not {!root} and [None]
      otherwise. *)

  val basename : t -> string option
  (** [basename path] is [Some component] if [path] is not {!root} and [None]
      otherwise. *)

  val relativize : root:t -> t -> t option
  (** [relativize ~root path] is [Some suffix] iff [path] is [root] or below
      [root] by normalized components. Equal paths return [Some {!root}]. *)

  val reach : from:t -> t -> string
  (** [reach ~from path] is relative syntax from [from] to [path].

      The returned string may contain [..] components. It is ["."] if [from] and
      [path] are equal. It is intended for display or integration with
      string-based consumers; it is not necessarily a valid {!Rel.t}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same path. *)

  val compare : t -> t -> int
  (** [compare a b] orders paths by normalized string form. The order is
      compatible with {!equal}. *)

  val hash : t -> int
  (** [hash path] is an unseeded hash compatible with {!equal}. *)

  module Set : Set.S with type elt = t
  (** Sets of relative paths. *)

  module Map : Map.S with type key = t
  (** Maps keyed by relative paths. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf path] formats [path] as a normalized relative path. *)
end

(** {1:abs Absolute paths} *)

module Abs : sig
  type t
  (** The type for normalized absolute lexical paths.

      {!root} renders as ["/"]; non-root values start with [/] and contain
      non-empty components separated by [/]. Components are never empty, [.],
      [..], contain [/], backslash, NUL, or start with an ASCII-letter drive
      prefix.

      An [Abs.t] is portable slash-rooted syntax, not evidence that a host path
      exists, is native to the current platform, or belongs to a workspace. *)

  val root : t
  (** [root] is the slash root. *)

  val is_root : t -> bool
  (** [is_root path] is [true] iff [path] is {!root}. *)

  val of_string : string -> (t, Error.t) result
  (** [of_string path] parses and normalizes slash-rooted [path].

      Normalization removes [.] components, collapses repeated [/] separators,
      and resolves [..]. Resolving [..] at {!root} stays at {!root}. Errors are:
      - {!Error.Empty} if it is [""];
      - {!Error.Relative} if it does not start with [/];
      - {!Error.Malformed_component} if a remaining component is malformed.

      [/] is the only separator. Backslash and drive prefixes are rejected, not
      interpreted as native absolute syntax. Backslash-rooted and drive-prefixed
      inputs do not start with [/] and therefore error with {!Error.Relative}.
  *)

  val of_string_exn : string -> t
  (** [of_string_exn path] is {!of_string}[ path].

      Raises [Invalid_argument] if [path] is invalid. Use this for trusted
      source-code literals; use {!of_string} at input boundaries. *)

  val to_string : t -> string
  (** [to_string path] is [path]'s normalized string form. {!root} is ["/"]. *)

  val components : t -> string list
  (** [components path] are [path]'s components. {!root} has no components. *)

  val add_component : t -> string -> (t, Error.t) result
  (** [add_component path component] is [Ok p] where [p] is [path] followed by
      [component], or [Error e] if [component] is malformed.

      [component] must satisfy {!Rel.is_component}. *)

  val append_rel : t -> Rel.t -> t
  (** [append_rel abs rel] appends [rel] below [abs]. {!Rel.root} is identity.
      Appending below {!root} preserves the slash root. *)

  val resolve : t -> string -> (t, Error.t) result
  (** [resolve base path] parses [path] as relative syntax below [base].

      [..] moves to the parent of the accumulated path; resolving [..] at
      {!root} stays at {!root}. Errors include {!Error.Empty} for [""],
      {!Error.Absolute} for slash-rooted, backslash-rooted, or drive-prefixed
      input, and {!Error.Malformed_component} for malformed components. *)

  val resolve_any : base:t -> string -> (t, Error.t) result
  (** [resolve_any ~base path] parses [path] as absolute-or-relative syntax:
      slash-rooted [path] is normalized as-is; relative [path] is normalized
      below [base]. Unlike {!resolve}, slash-rooted input is accepted rather
      than rejected. Errors are {!Error.Empty} for [""], {!Error.Absolute} for
      backslash-rooted or drive-prefixed input, and {!Error.Malformed_component}
      for malformed components. *)

  val parent : t -> t option
  (** [parent path] is [Some parent] if [path] is not {!root} and [None]
      otherwise. *)

  val basename : t -> string option
  (** [basename path] is [Some component] if [path] is not {!root} and [None]
      otherwise. *)

  val relativize : root:t -> t -> Rel.t option
  (** [relativize ~root path] is [Some suffix] iff [path] is [root] or below
      [root] by normalized components. Equal paths return [Some Rel.root]. *)

  val reach : from:t -> t -> string
  (** [reach ~from path] is relative syntax from [from] to [path].

      The returned string may contain [..] components. It is ["."] if [from] and
      [path] are equal. It is intended for display or integration with
      string-based consumers; it is not necessarily a valid {!Rel.t}. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same path. *)

  val compare : t -> t -> int
  (** [compare a b] orders paths by normalized string form. The order is
      compatible with {!equal}. *)

  val hash : t -> int
  (** [hash path] is an unseeded hash compatible with {!equal}. *)

  module Set : Set.S with type elt = t
  (** Sets of absolute paths. *)

  module Map : Map.S with type key = t
  (** Maps keyed by absolute paths. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf path] formats [path] as a normalized absolute path. *)
end
