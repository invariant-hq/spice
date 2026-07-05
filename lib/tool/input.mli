(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Typed JSON input contracts for executable tools.

    An input contract pairs two related but distinct descriptions of a tool's
    input:

    - a {!Jsont.t} runtime codec, used by {!Spice_tool.Call.decode} to turn
      provider JSON into the value passed to the tool handler;
    - a JSON Schema object, exposed by {!Spice_tool.input_schema} for model or
      provider declarations.

    [Input] stores the schema as data. It checks only that the schema root is a
    JSON object; it does not validate JSON Schema semantics, infer a schema from
    the codec, or check that the schema and codec accept the same values. *)

type 'a t
(** The type for tool input contracts decoded to values of type ['a].

    The JSON Schema projection and the runtime codec are fixed when the contract
    is constructed. Decoding uses only the codec. *)

val make : 'a Jsont.t -> schema:Jsont.json -> 'a t
(** [make codec ~schema] is an input contract decoded with [codec].

    [schema] is the JSON Schema object advertised externally for this input
    contract. The schema is retained unchanged and later returned by {!schema}.

    Raises [Invalid_argument] if [schema] is not a JSON object. *)

val empty : unit t
(** [empty] is the no-argument object input contract.

    [empty] decodes exactly an object with no members to [()] and rejects
    non-objects and unknown object members. Its schema is an object schema with
    no properties and [additionalProperties] set to [false]. *)

val schema : _ t -> Jsont.json
(** [schema t] is the model-visible JSON Schema object retained by [t]. *)

val decode : 'a t -> Jsont.json -> ('a, string) result
(** [decode t json] decodes [json] with [t]'s runtime codec.

    The result is [Ok input] if [json] satisfies the codec and
    [Error diagnostic] otherwise. [diagnostic] is a human-readable decoder
    diagnostic from [Jsont]; callers must not rely on it for stable programmatic
    matching. [diagnostic] is plain text and carries no ANSI styling. *)
