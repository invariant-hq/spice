(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Model-facing OCaml type-at-position tool.

    [ocaml_type_at] reports the inferred type, and optionally the odoc
    documentation, of the OCaml entity at a source position. It delegates
    inference to Merlin's [type-enclosing] command (with [document] for
    documentation) and treats Dune as Merlin's project-context provider. The
    tool does not parse OCaml source itself, does not read compiler
    [.cmt]/[.cmti] artifacts, does not link the Merlin libraries, and does not
    build or clean the project. Type strings are Merlin's own printer output,
    returned verbatim and byte-bounded; the tool does not reformat them. *)

val name : string
(** Stable tool name, ["ocaml_type_at"]. *)

val description : string
(** Model-visible tool description used by {!tool}. *)

val default_program : string list
(** Default Merlin invocation prefix, [["ocamlmerlin"]] — Merlin resolved
    through [PATH]. Merlin is reached through an argv {e prefix} (not a single
    program name) so a toolchain that exposes it only via
    [dune tools exec ocamlmerlin --] is supported. *)

val default_max_enclosings : int
(** Default number of enclosing type frames returned by {!run}, [1]. *)

val max_enclosings_limit : int
(** Maximum accepted explicit [max_enclosings], [8]. Kept low because each frame
    beyond the innermost costs a full Merlin re-type of the buffer. *)

val max_verbosity : int
(** Maximum accepted explicit [verbosity]. *)

module Input : sig
  (** Typed type-at requests over a source position.

      The query is deliberately position-based. A bare name is ambiguous in
      OCaml under opens, shadowing, labels, constructors, and generated code;
      callers that only have a name should first locate a concrete file
      position. *)

  type t

  val make :
    ?max_enclosings:int ->
    ?verbosity:int ->
    ?documentation:bool ->
    path:string ->
    line:int ->
    column:int ->
    unit ->
    t
  (** [make ~path ~line ~column ()] requests the type at [line]:[column] in
      [path].

      [path] is workspace-relative or a workspace-contained absolute path.
      [line] is 1-based and [column] is a 0-based byte column. [max_enclosings]
      defaults to {!default_max_enclosings} and is the number of enclosing
      frames returned, innermost-first. [verbosity] defaults to [0] and sets
      Merlin's alias/module-type expansion depth. [documentation] defaults to
      [false].

      Raises [Invalid_argument] if [path] is empty, [line < 1], [column < 0],
      [max_enclosings < 1], [max_enclosings > max_enclosings_limit],
      [verbosity < 0], or [verbosity > max_verbosity]. *)

  val path : t -> string
  (** [path t] is the requested source-file path string. *)

  val position : t -> Spice_ocaml.Position.t
  (** [position t] is the cursor position of the query. *)

  val max_enclosings : t -> int
  (** [max_enclosings t] is the requested maximum number of enclosing frames. *)

  val verbosity : t -> int
  (** [verbosity t] is the requested Merlin expansion depth. *)

  val documentation : t -> bool
  (** [documentation t] is [true] when the entity's odoc comment is requested.
  *)

  val contract : t Spice_tool.Input.t
  (** [contract] is the JSON input contract for tool calls. Unknown fields are
      rejected. *)

  val to_json : t -> Jsont.json
  (** [to_json t] encodes [t] as provider JSON. Absent optional fields are
      omitted. *)

  val decode : Jsont.json -> (t, string) result
  (** [decode json] decodes [json] with {!contract}. *)
end

module Frame : sig
  (** A single enclosing type frame. *)

  type t
  (** An inferred type over a source location.

      [location] is a {!Spice_ocaml.Location.t} — the same per-item positional
      evidence shape {!Ocaml_find_references.Reference} carries, so a host
      reading any OCaml-tool output handles positions uniformly. Every frame of
      a single query lies in the query file, so [Location.path] equals
      {!Output.path}; it is carried per-frame for family consistency rather than
      factored out. [type_string] is Merlin's printed type for that range,
      byte-bounded; [truncated] is [true] when it was cut to the per-frame byte
      budget. *)

  val make :
    location:Spice_ocaml.Location.t -> type_string:string -> truncated:bool -> t
  (** [make ~location ~type_string ~truncated] is a type frame. *)

  val location : t -> Spice_ocaml.Location.t
  (** [location t] is the source location the type covers. Its path is the query
      file ({!Output.path}) for every frame. *)

  val type_string : t -> string
  (** [type_string t] is the inferred type as printed by Merlin, possibly a
      bounded prefix when {!truncated} is [true]. *)

  val truncated : t -> bool
  (** [truncated t] is [true] iff [type_string t] was cut to the byte budget. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on frames, by location then type string. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are equal. *)
end

module Documentation : sig
  (** The documentation slot of a type-at result. *)

  type t =
    | Not_requested  (** The request did not set [documentation]. *)
    | Not_available of string
        (** Documentation was requested but Merlin returned none; the string is
            the reason (no comment, builtin, not in environment). *)
    | Available of { text : string; truncated : bool }
        (** The entity's odoc comment. [truncated] is [true] when [text] was cut
            to the byte budget. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on documentation slots. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are equal. *)
end

module Output : sig
  (** Typed type-at output retained by completed tool calls. *)

  type t

  val query : t -> Input.t
  (** [query t] is the request that produced [t]. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is the resolved workspace path that was queried. It mirrors
      {!Ocaml_find_references.Output.path}: the queried file, exposed once,
      while each {!Frame.location} additionally carries it per item (they
      coincide, since all frames are in-file). *)

  val frames : t -> Frame.t list
  (** [frames t] are the returned type frames, innermost-first, adjacent
      duplicates removed and bounded by [Input.max_enclosings]. The list is
      non-empty for completed outputs. *)

  val innermost : t -> Frame.t
  (** [innermost t] is the smallest enclosing frame, the direct type at the
      cursor. Equivalent to the head of {!frames}. *)

  val documentation : t -> Documentation.t
  (** [documentation t] is the documentation slot for [t]. *)

  val verbosity : t -> int
  (** [verbosity t] is the effective Merlin expansion depth used. *)

  val backend : t -> string
  (** [backend t] is the resolver backend name, ["ocamlmerlin"]. *)

  val of_tool_output : Spice_tool.Output.t -> t option
  (** [of_tool_output output] is the typed output retained in [output] iff
      [output] was produced by this tool. *)
end

val permissions :
  workspace:Spice_workspace.t ->
  Input.t ->
  Spice_permission.Request.t list
(** [permissions ~workspace input] is the source-file read required by the type
    lookup. Merlin is a fixed sealed implementation detail. *)

val run :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  Spice_tool.Context.t ->
  Input.t ->
  Output.t Spice_tool.Result.t
(** [run ~sandbox ~fs ~workspace ctx input] reads [input]'s source file and invokes
    [ocamlmerlin type-enclosing] from the workspace root with that source on
    standard input, requesting frame types lazily by index up to
    [Input.max_enclosings]. When [Input.documentation] is set it additionally
    invokes [ocamlmerlin document] for the same position; a documentation
    failure does not fail the call.

    The result is completed with {!Output.t} on success, interrupted if [ctx] is
    cancelled, failed as [`Not_found] when no type is inferable at the position
    (whitespace, comments, or code that does not typecheck there) or the source
    cannot be read, failed as [`Unavailable] when Merlin cannot be started,
    failed as [`Timed_out] on timeout, and failed as [`Failed] for malformed
    Merlin output or other command failures. [program] defaults to
    {!default_program}. *)

val tool :
  sandbox:Spice_sandbox.t ->
  ?program:string list ->
  fs:_ Eio.Path.t ->
  workspace:Spice_workspace.t ->
  unit ->
  Spice_tool.t
(** [tool ~sandbox ~fs ~workspace ()] is the erased model-facing tool for {!run}. *)
