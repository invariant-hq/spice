(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structured sandbox errors. *)

type t
(** The type for recoverable sandbox errors.

    Spawn-boundary APIs return these errors in [result] values. Use {!message}
    or {!pp} for diagnostics and {!to_json} for the machine-readable projection,
    whose ["kind"] member discriminates the class. *)

val unavailable : string -> t
(** [unavailable message] reports that sandbox enforcement is unavailable.

    Raises [Invalid_argument] if [message] is empty. *)

val invalid_request : string -> t
(** [invalid_request message] reports an invalid sandbox request.

    Raises [Invalid_argument] if [message] is empty. *)

val invalid_cwd : string -> t
(** [invalid_cwd message] reports that a spawn working directory is missing,
    not a directory, or outside the confined readable roots. *)

val message : t -> string
(** [message t] is the human-readable diagnostic. *)

val equal : t -> t -> bool
(** [equal a b] is [true] iff [a] and [b] have the same kind and message. *)

val to_json : t -> Jsont.json
(** [to_json t] is the canonical JSON projection: an object with ["kind"]
    (["unavailable"], ["invalid_request"], or ["invalid_cwd"]) and
    ["message"]. *)

val pp : Format.formatter -> t -> unit
(** [pp] formats [message t]. *)
