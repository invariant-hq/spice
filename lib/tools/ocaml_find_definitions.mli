(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-facing OCaml definition lookup tool.

    [ocaml_find_definitions] locates the definition, declaration, or type
    definition for an OCaml identifier in a source file. It delegates semantic
    resolution to Merlin's [locate] commands and treats Dune as Merlin's
    project-context provider. The tool does not parse OCaml source itself, does
    not inspect compiler typedtrees directly, and does not build or clean the
    project. *)

val name : string
(** Stable tool name, ["ocaml_find_definitions"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

module Input : sig
  module Kind : sig
    (** Definition lookup kinds. *)

    type t =
      | Definition
      | Declaration
      | Type_definition
          (** The lookup Merlin should perform.

              [Definition] asks Merlin to prefer an implementation location.
              [Declaration] asks Merlin to prefer an interface location.
              [Type_definition] asks Merlin for the definition of the inferred
              type at the cursor. Merlin does not accept an explicit identifier
              for this mode. *)

    val to_string : t -> string
    (** [to_string t] is the provider-facing name for [t], one of
        ["definition"], ["declaration"], or ["type-definition"]. *)

    val compare : t -> t -> int
    (** [compare a b] is a total order on lookup kinds. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same lookup kind. *)
  end

  type t
  (** A definition lookup request.

      [line] is 1-based. [column] is a 0-based byte offset in the line, matching
      OCaml compiler and Merlin locations. [identifier], when present, is passed
      to Merlin as the locate prefix; otherwise Merlin reconstructs the
      identifier at the source position. *)

  val make :
    ?identifier:string ->
    ?kind:Kind.t ->
    path:string ->
    line:int ->
    column:int ->
    unit ->
    t
  (** [make ~path ~line ~column ()] is a lookup request.

      Raises [Invalid_argument] if [path] is empty, [line < 1], [column < 0],
      [identifier] is empty when present, or [identifier] is present with
      [kind = Type_definition]. *)

  val path : t -> string
  (** [path t] is the requested source-file path string. *)

  val line : t -> int
  (** [line t] is the 1-based cursor line. *)

  val column : t -> int
  (** [column t] is the 0-based byte column of the cursor. *)

  val identifier : t -> string option
  (** [identifier t] is the explicit Merlin locate prefix, if any. *)

  val kind : t -> Kind.t
  (** [kind t] is the requested lookup kind. *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. *)

  val to_json : t -> Jsont.json
  (** [to_json t] encodes [t] as provider JSON. Absent optional fields are
      omitted. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

module Definition : sig
  (** Located OCaml definitions. *)

  module Target : sig
    (** Definition target locations, inside or outside the workspace. *)

    type t =
      | Workspace of Spice_ocaml.Location.t
          (** A definition in one of the configured workspace roots. *)
      | External of { path : string; position : Spice_ocaml.Position.t }
          (** A definition reported by Merlin outside the configured workspace.

              This includes installed libraries, stdlib source locations when
              available, and generated/build paths not admitted as workspace
              roots. *)

    val compare : t -> t -> int
    (** [compare a b] is a total order on targets. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] denote the same target location.
    *)
  end

  type t
  (** A located OCaml definition target. *)

  val make : target:Target.t -> unit -> t
  (** [make ~target ()] is a definition located at [target]. *)

  val target : t -> Target.t
  (** [target t] is [t]'s location. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on definitions, by target. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have equal targets. *)
end

module Output : sig
  (** Typed definition-lookup output. *)

  type index_status =
    | Not_applicable
    | Unknown
        (** Project-index freshness precision. [Not_applicable] is reported when
            the cursor is already at the definition, so Merlin consults no
            project index; [Unknown] is reported for every resolved target
            because Merlin's [locate] may draw on a project index whose
            freshness its CLI does not expose. Mirrors
            {!Ocaml_find_references.Output.index_status}. *)

  type t
  (** The typed output retained by completed [ocaml_find_definitions] calls. *)

  val input : t -> Input.t
  (** [input t] is the decoded request that produced this output. *)

  val index_status : t -> index_status
  (** [index_status t] is the trust signal for the resolved definitions. *)

  val definitions : t -> Definition.t list
  (** [definitions t] is the ordered definition result set.

      The current Merlin backend returns at most one definition. The output type
      is a list so the tool contract can grow to multi-result backends without
      changing callers' typed evidence path. *)

  val definition_count : t -> int
  (** [definition_count t] is the number of definitions returned. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is [Some t] if [output] was produced by this tool
      and retained typed evidence, and [None] otherwise. *)
end

val permissions :
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace input] is the source-file read required by the
    lookup. Merlin is a fixed sealed implementation detail. *)

val run :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  Spice_tool.Context.t ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace ctx input] reads [input.path], invokes [ocamlmerlin]
    from the workspace root with that source on stdin, and returns the located
    definition.

    The result is completed with {!Output.t} on successful lookup, interrupted
    if [ctx] is cancelled, failed as [`Not_found] for Merlin not-found and
    invalid-context responses, failed as [`Unavailable] when Merlin cannot be
    started, and failed as [`Failed] for malformed Merlin output or other
    command failures. *)

val tool :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased model-facing tool for {!run}. *)
