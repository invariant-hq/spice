(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-visible content blocks.

    Content is the shared payload language for user messages and tool results.
    It is intentionally small: visible text and opaque media references. Content
    values are inert; provider adapters decide which media types and source
    forms they can encode for a given model API. *)

type media_source = [ `Uri of string | `Base64 of string ]
(** The type for model-visible media sources.

    [`Uri uri] is an adapter-interpreted URI or URL. [`Base64 data] is base64
    payload text. {!media} accepts only non-empty source strings. MIME type,
    URI, and base64 validation belong to provider adapters. *)

type t = private
  | Text of string
  | Media of { media_type : string; source : media_source }
      (** The type for model-visible content blocks.

          Text and media strings are non-empty. *)

val text : string -> t
(** [text s] is text content [s].

    Raises [Invalid_argument] if [s] is empty. *)

val media : media_type:string -> media_source -> t
(** [media ~media_type source] is media content with MIME type [media_type].

    Raises [Invalid_argument] if [media_type] or the source string is empty. *)

val jsont : t Jsont.t
(** [jsont] maps content blocks to tagged JSON objects.

    Decoding errors if the object violates content invariants. *)
