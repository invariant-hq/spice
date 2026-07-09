(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Stable SHA-256 digests for exact byte sequences.

    A value is the 32-byte SHA-256 output for a byte sequence. Construct values
    with {!string}; serialize them with {!to_hex} for stable text identifiers
    and diagnostics, or {!to_raw_string} for byte-oriented protocols such as
    PKCE challenge construction. Derive a truncated identifier from several
    fields with {!key}.

    Inputs are bytes, not text. Hashing applies no Unicode normalization,
    line-ending normalization, NUL handling, or character-set conversion. On the
    raw {!string}/{!to_hex} path, a caller that folds several fields into one
    input is responsible for its own domain separation; {!key} performs
    length-framed domain and field encoding for derived identifiers. This module
    is deterministic and pure, but it is not an authentication boundary and does
    not provide keyed authentication. *)

(** {1:types Types} *)

type t
(** SHA-256 digest value.

    Values produced by this module contain exactly 32 raw digest bytes. The
    representation is opaque; use {!to_hex} or {!to_raw_string} to serialize a
    value. *)

(** {1:hashing Hashing} *)

val string : string -> t
(** [string s] is the SHA-256 digest of [s]'s exact bytes.

    [s] may contain arbitrary bytes, including invalid UTF-8 and NUL bytes. *)

(** {1:serializing Serializing} *)

val to_hex : t -> string
(** [to_hex t] is [t] as 64 lowercase hexadecimal characters. The returned
    string contains only ['0'] through ['9'] and ['a'] through ['f']. *)

val to_raw_string : t -> string
(** [to_raw_string t] is [t]'s 32 raw digest bytes.

    The returned string is binary data, not hexadecimal text, and may contain
    NUL or non-printable bytes. *)

(** {1:deriving Deriving identifiers} *)

val key : length:int -> domain:string -> string list -> string
(** [key ~length ~domain parts] is the first [length] lowercase hexadecimal
    characters of the SHA-256 digest of [domain] and [parts] encoded as
    length-framed byte strings. The framing is injective over arbitrary byte
    strings, including embedded NUL bytes. Different [domain] values produce
    different input frames for the same [parts].

    [domain] should be a stable, versioned name for the caller's derived-id
    namespace. [length] is required so the collision-risk choice stays explicit
    at each call site. Short prefixes are suitable for display or local
    generated identifiers only when the caller accepts the collision risk for
    the chosen length.

    Raises [Invalid_argument] if [length] is not in the range \[[0];[64]\] or if
    [domain] is empty. *)

(** {1:comparing Comparing} *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] are the same digest. *)

val pp : Format.formatter -> t -> unit
(** [pp ppf t] formats [t] as {!to_hex} output. *)

(** {1:identities Content identities} *)

module Identity : sig
  (** Content identities for complete byte strings.

      An identity is a non-authenticating cache and stale-check token for a
      complete byte string. It records the SHA-256 digest and the byte length as
      a canonical [sha256:<digest>:<length>] token. Identities are not a
      security boundary. *)

  type t
  (** The type for content identities.

      Values are canonical [sha256:<digest>:<length>] tokens. [<digest>] is 64
      lowercase hexadecimal characters. [<length>] is the decimal byte length of
      the content, fits in [int], and has no leading zeroes except ["0"]. *)

  module Parse_error : sig
    (** Identity parse errors. *)

    (** The type for identity parse errors. *)
    type t =
      | Invalid_identity
          (** Any violation of the canonical identity grammar. *)

    val message : t -> string
    (** [message e] is a human-readable diagnostic for [e]. It is not stable
        enough for programmatic matching. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf e] formats {!message} output. *)
  end

  val of_contents : string -> t
  (** [of_contents contents] is the identity of [contents]' exact bytes. *)

  val to_string : t -> string
  (** [to_string t] is the canonical string and JSON representation of [t]. *)

  val of_string : string -> (t, Parse_error.t) result
  (** [of_string s] is [Ok t] if [s] is a canonical identity string and
      [Error Parse_error.Invalid_identity] otherwise.

      The accepted grammar is exactly [sha256:<digest>:<length>]. The parser
      rejects empty input, uppercase or non-hex digest characters, wrong digest
      length, extra or missing fields, non-decimal or signed lengths,
      leading-zero lengths other than ["0"], and lengths greater than [max_int].
  *)

  val digest_hex : t -> string
  (** [digest_hex t] is [t]'s 64-character lowercase SHA-256 digest. *)

  val byte_length : t -> int
  (** [byte_length t] is the byte length of the content identified by [t]. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are the same identity. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t]'s stable string representation. *)

  val jsont : t Jsont.t
  (** [jsont] maps identities to JSON strings. Decoding validates the same
      canonical grammar as {!of_string} and reports {!Parse_error.message}
      diagnostics. *)
end
