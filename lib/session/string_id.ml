(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

(* Shared implementation of the string-backed identifier modules of
   [spice_session]. Each instantiation is generative, so every id module
   keeps its own abstract type. *)

module type S = sig
  type t

  val of_string : string -> t
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
  val jsont : t Jsont.t
end

module Make
    (Spec : sig
      val module_path : string
      (** Fully qualified module path used in [Invalid_argument] messages, for
          example ["Spice_session.Turn.Id"]. *)

      val kind : string
      (** JSON codec kind, for example ["turn id"]. *)
    end)
    () : S = struct
  type t = string

  let invalid message = invalid_arg' Spec.module_path "of_string" message

  let of_string id =
    if String.is_empty id then invalid "id must not be empty";
    id

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t

  let jsont =
    Jsont.map ~kind:Spec.kind
      ~dec:(fun id -> decode_invalid_arg (fun () -> of_string id))
      ~enc:to_string Jsont.string
end
