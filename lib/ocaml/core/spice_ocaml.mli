(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** OCaml language facts shared by OCaml-specific tools.

    This library is the small vocabulary that Dune, Merlin, odoc, and
    tool-facing adapters convert into. It is pure and owns no compiler service,
    RPC connection, filesystem authority, cache, or host lifecycle. *)

(** {1 Source coordinates} *)

module Position : sig
  (** Source positions. *)

  type t
  (** A source position.

      Lines are 1-based. Columns are 0-based byte offsets in the line. This
      matches OCaml compiler locations and keeps backend adapters lossless. *)

  val make : line:int -> column:int -> t
  (** [make ~line ~column] is a source position.

      Raises [Invalid_argument] if [line < 1] or [column < 0]. *)

  val line : t -> int
  (** [line t] is [t]'s 1-based line number. *)

  val column : t -> int
  (** [column t] is [t]'s 0-based column, a byte offset in the line. *)

  val compare : t -> t -> int
  (** [compare a b] orders positions by line, then by column. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same line and column. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] as ["line:column"]. *)
end

module Range : sig
  (** Source ranges over {!Position.t} endpoints. *)

  type t
  (** A half-open source range.

      [start] is included and [end_] is excluded. Empty ranges are valid and
      represent points. *)

  val make : start:Position.t -> end_:Position.t -> t
  (** [make ~start ~end_] is the half-open range from [start] to [end_].

      Raises [Invalid_argument] if [end_] is before [start]. *)

  val point : Position.t -> t
  (** [point p] is an empty range at [p]. *)

  val start : t -> Position.t
  (** [start t] is [t]'s included start position. *)

  val end_ : t -> Position.t
  (** [end_ t] is [t]'s excluded end position. *)

  val contains : outer:t -> t -> bool
  (** [contains ~outer t] is [true] iff [t] lies within [outer], that is
      [outer]'s start is at or before [t]'s start and [t]'s end is at or before
      [outer]'s end. *)

  val compare : t -> t -> int
  (** [compare a b] orders ranges by start position, then by end position. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have equal start and end positions.
  *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] as ["start-end"]. *)
end

module Location : sig
  (** File locations pairing a workspace path with a source {!Range.t}. *)

  type t
  (** A workspace file location. *)

  val make : path:Spice_workspace.Path.t -> range:Range.t -> t
  (** [make ~path ~range] is the location of [range] within [path]. *)

  val path : t -> Spice_workspace.Path.t
  (** [path t] is [t]'s workspace file path. *)

  val range : t -> Range.t
  (** [range t] is [t]'s source range. *)

  val start : t -> Position.t
  (** [start t] is [Range.start (range t)]. *)

  val end_ : t -> Position.t
  (** [end_ t] is [Range.end_ (range t)]. *)

  val compare : t -> t -> int
  (** [compare a b] orders locations by path, then by range. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] as ["path:range"], using the path's display form.
  *)
end

module Module_name : sig
  (** OCaml module names. *)

  type t
  (** An OCaml compilation-unit name. *)

  val make : string -> t
  (** [make name] is an OCaml module name.

      [name] must be an ASCII OCaml module identifier: it starts with an
      uppercase letter and continues with letters, digits, underscores, or
      apostrophes. Raises [Invalid_argument] otherwise. *)

  val to_string : t -> string
  (** [to_string t] is [t] as a string. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] as its module name. *)
end

(** {1 Diagnostics} *)

module Diagnostic : sig
  (** Diagnostics reported by OCaml tools and the build system.

      A {!type:t} carries a message, a {!Source.t}, and a {!Severity.t}, and may
      add a {!Location.t}, a code, {!Tag.t} markers, and {!Related.t}
      information. *)

  module Severity : sig
    (** Diagnostic severity levels, ordered from [Error] (most urgent) to [Hint]
        (least urgent). *)

    type t =
      | Error  (** An error. *)
      | Warning  (** A warning. *)
      | Information  (** Informational feedback. *)
      | Hint  (** A hint or suggestion. *)

    val compare : t -> t -> int
    (** [compare a b] orders severities from most to least urgent: [Error] <
        [Warning] < [Information] < [Hint]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same severity. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as its lowercase name, one of ["error"],
        ["warning"], ["information"], or ["hint"]. *)
  end

  module Source : sig
    (** Producers of diagnostics. *)

    type t = private
      | Dune
      | Merlin
      | Compiler
      | Ocamlformat
      | Odoc
      | Other of string
          (** The producer of a diagnostic. [Other label] is for integrations
              that are not part of the core vocabulary.

              [label] must be non-empty, must not collide with a built-in
              source, and must use lowercase ASCII words separated by hyphens.
              Construct other sources with {!other}; direct construction is
              intentionally unavailable so those invariants cannot be bypassed.
          *)

    val dune : t
    (** [dune] is the source for diagnostics produced by Dune. *)

    val merlin : t
    (** [merlin] is the source for diagnostics produced by Merlin. *)

    val compiler : t
    (** [compiler] is the source for diagnostics produced by the OCaml compiler.
    *)

    val ocamlformat : t
    (** [ocamlformat] is the source for diagnostics produced by ocamlformat. *)

    val odoc : t
    (** [odoc] is the source for diagnostics produced by odoc. *)

    val other : string -> t
    (** [other label] is [Other label].

        Raises [Invalid_argument] if [label] is empty, malformed, or collides
        with a built-in source such as ["dune"] or ["merlin"]. *)

    val to_string : t -> string
    (** [to_string t] is [t]'s label: the lowercase producer name for a built-in
        source, or [label] for [Other label]. *)

    val compare : t -> t -> int
    (** [compare a b] orders sources with the built-in producers first in a
        fixed order ([Dune], [Merlin], [Compiler], [Ocamlformat], [Odoc]) and
        [Other] sources last, ties broken by label. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same source. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as its label (see {!to_string}). *)
  end

  module Tag : sig
    (** Diagnostic tags describing how a span should be treated. *)

    type t =
      | Unnecessary  (** Marks unused or unreachable code. *)
      | Deprecated  (** Marks use of a deprecated construct. *)

    val compare : t -> t -> int
    (** [compare a b] orders tags with [Unnecessary] before [Deprecated]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] are the same tag. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as ["unnecessary"] or ["deprecated"]. *)
  end

  module Related : sig
    (** Secondary locations and messages attached to a diagnostic. *)

    type t
    (** The type for related diagnostic information: a message and an optional
        {!Location.t}. *)

    val make : ?location:Location.t -> string -> t
    (** [make ?location message] is related diagnostic information.

        Raises [Invalid_argument] if [message] is empty. *)

    val message : t -> string
    (** [message t] is [t]'s message. *)

    val location : t -> Location.t option
    (** [location t] is [t]'s location, or [None] when the producer gave no
        precise location. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as ["location: message"], or as just the message
        when [t] has no location. *)
  end

  type t
  (** A compiler, build, or OCaml tooling diagnostic.

      Diagnostics may be attached to a location, or to a source with only a
      message when the producer did not report a precise file range. *)

  val make :
    ?location:Location.t ->
    ?code:string ->
    ?tags:Tag.t list ->
    ?related:Related.t list ->
    source:Source.t ->
    severity:Severity.t ->
    string ->
    t
  (** [make ... message] is a diagnostic.

      Raises [Invalid_argument] if [message] is empty, [code] is empty when
      present, or [tags] contains duplicates. *)

  val message : t -> string
  (** [message t] is [t]'s human-readable message. *)

  val source : t -> Source.t
  (** [source t] is the producer of [t]. *)

  val severity : t -> Severity.t
  (** [severity t] is [t]'s severity. *)

  val location : t -> Location.t option
  (** [location t] is [t]'s location, or [None] when the producer reported no
      precise file range. *)

  val code : t -> string option
  (** [code t] is [t]'s diagnostic code, or [None] when the producer reported
      none. *)

  val tags : t -> Tag.t list
  (** [tags t] is [t]'s tags. *)

  val related : t -> Related.t list
  (** [related t] is [t]'s related information. *)

  val compare : t -> t -> int
  (** [compare a b] is a total order on diagnostics. It compares by location,
      then source, severity, code, message, tags, and related information. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] are equal in all fields. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for users as ["source[severity]: message"],
      prefixed with ["location: "] when [t] has a location. *)
end

(** {1 Project descriptions} *)

module Project : sig
  (** Normalized project descriptions for agent-facing tools.

      A {!type:t} groups the project's {!Component.t} nodes and {!Test.t}
      entries. Build them with {!make}, which validates that component
      dependencies and tests refer to known components. *)

  module Deps : sig
    (** Optionally-computed dependency information. *)

    type 'a t =
      | Unknown
      | Known of 'a list
          (** Dependency information that may not have been requested from the
              backend.

              [Unknown] means the producer did not compute this dependency set.
              [Known []] means it computed the set and found no dependencies. *)

    val unknown : 'a t
    (** [unknown] is [Unknown], the absence of computed dependency information.
    *)

    val known : 'a list -> 'a t
    (** [known values] is [Known values]. *)
  end

  module Compilation_unit : sig
    (** OCaml compilation units belonging to a project component. *)

    type t
    (** An OCaml compilation unit that belongs to a project component. *)

    val make :
      ?impl:Spice_workspace.Path.t ->
      ?intf:Spice_workspace.Path.t ->
      ?interface_deps:Module_name.t Deps.t ->
      ?implementation_deps:Module_name.t Deps.t ->
      Module_name.t ->
      t
    (** [make ... name] is a compilation unit.

        [impl] and [intf] are source files when Dune reports them inside the
        workspace. Dependency names are direct OCaml module dependencies as
        reported by the backend.

        Dependencies default to {!Deps.Unknown}. *)

    val name : t -> Module_name.t
    (** [name t] is [t]'s module name. *)

    val impl : t -> Spice_workspace.Path.t option
    (** [impl t] is the path to [t]'s implementation file, or [None] when Dune
        did not report one inside the workspace. *)

    val intf : t -> Spice_workspace.Path.t option
    (** [intf t] is the path to [t]'s interface file, or [None] when Dune did
        not report one inside the workspace. *)

    val interface_deps : t -> Module_name.t Deps.t
    (** [interface_deps t] is the direct module dependencies of [t]'s interface.
    *)

    val implementation_deps : t -> Module_name.t Deps.t
    (** [implementation_deps t] is the direct module dependencies of [t]'s
        implementation. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as its module name. *)
  end

  module Component : sig
    (** Project component nodes: local libraries, executables, and external
        dependencies. *)

    module Id : sig
      (** Component identities. *)

      type t
      (** Stable component identity inside one project description. *)

      val library : string -> t
      (** [library name] is the id for a local library.

          Raises [Invalid_argument] if [name] is empty or contains NUL. *)

      val external_library : string -> t
      (** [external_library name] is the id for an external library.

          Raises [Invalid_argument] if [name] is empty or contains NUL. *)

      val executable : dir:Spice_workspace.Path.t -> name:string -> t
      (** [executable ~dir ~name] is the id for an executable declared in [dir].

          Raises [Invalid_argument] if [name] is empty or contains NUL. *)

      val to_string : t -> string
      (** [to_string t] is [t]'s stable string form. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf t] formats [t] as its string form. *)
    end

    module Kind : sig
      (** Component kinds. *)

      type t =
        | Local_library  (** A library defined in the workspace. *)
        | External_library  (** A library outside the workspace. *)
        | Executable  (** An executable defined in the workspace. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf t] formats [t] as ["library"], ["external-library"], or
          ["executable"]. *)
    end

    type t
    (** A library, executable, or external dependency node.

        Components should be built with {!local_library}, {!external_library},
        or {!executable} so the id, kind, and source directory agree. [requires]
        stores component ids. Adapters are responsible for resolving
        Dune-specific ids, digests, and external library names into this
        project-local id space before constructing the final {!type:Project.t}.
    *)

    val local_library :
      ?source_dir:Spice_workspace.Path.t ->
      ?location:Location.t ->
      ?units:Compilation_unit.t list ->
      ?requires:Id.t Deps.t ->
      name:string ->
      unit ->
      t
    (** [local_library ?source_dir ?location ?units ?requires ~name ()] is a
        local library component named [name]. [source_dir] is the workspace
        directory containing the library stanza, when known.

        [requires] defaults to {!Deps.Unknown}. Raises [Invalid_argument] if
        [name] is empty or [requires] contains duplicate ids. *)

    val external_library :
      ?source_dir:Spice_workspace.Path.t ->
      ?location:Location.t ->
      ?units:Compilation_unit.t list ->
      ?requires:Id.t Deps.t ->
      name:string ->
      unit ->
      t
    (** [external_library ?source_dir ?location ?units ?requires ~name ()] is an
        external library component named [name].

        [source_dir] is present only when the producer can map the external
        library's source directory into the current workspace. [requires]
        defaults to {!Deps.Unknown}. Raises [Invalid_argument] if [name] is
        empty or [requires] contains duplicate ids. *)

    val executable :
      dir:Spice_workspace.Path.t ->
      ?location:Location.t ->
      ?units:Compilation_unit.t list ->
      ?requires:Id.t Deps.t ->
      name:string ->
      unit ->
      t
    (** [executable ~dir ?location ?units ?requires ~name ()] is an executable
        component named [name] declared in [dir]. [dir] is part of the
        executable's stable component id.

        [requires] defaults to {!Deps.Unknown}. Raises [Invalid_argument] if
        [name] is empty or [requires] contains duplicate ids. *)

    val with_requires : Id.t Deps.t -> t -> t
    (** [with_requires requires t] is [t] with [requires].

        Raises [Invalid_argument] if [requires] contains duplicate ids. *)

    val id : t -> Id.t
    (** [id t] is [t]'s stable component id. *)

    val name : t -> string
    (** [name t] is [t]'s name. *)

    val kind : t -> Kind.t
    (** [kind t] is [t]'s kind. *)

    val source_dir : t -> Spice_workspace.Path.t option
    (** [source_dir t] is the workspace directory of [t]'s stanza, or [None]
        when it is unknown. *)

    val location : t -> Location.t option
    (** [location t] is [t]'s declaration location, or [None] when unknown. *)

    val units : t -> Compilation_unit.t list
    (** [units t] is [t]'s compilation units. *)

    val requires : t -> Id.t Deps.t
    (** [requires t] is [t]'s direct component dependencies, as component ids.
    *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as its kind followed by its name. *)
  end

  module Test : sig
    (** Runnable test entries reported by the build system. *)

    type t
    (** A runnable test entry reported by the build system. *)

    val make :
      ?component:Component.Id.t ->
      ?package:string ->
      ?location:Location.t ->
      name:string ->
      source_dir:Spice_workspace.Path.t ->
      target:string ->
      enabled:bool ->
      unit ->
      t
    (** [make ...] is a test description.

        [target] is the Dune target or alias to run. [component] is the project
        component this test exercises when known. Raises [Invalid_argument] if
        [name], [package], or [target] is empty. *)

    val component : t -> Component.Id.t option
    (** [component t] is the id of the component this test exercises, or [None]
        when unknown. *)

    val name : t -> string
    (** [name t] is [t]'s name. *)

    val source_dir : t -> Spice_workspace.Path.t
    (** [source_dir t] is the workspace directory [t] runs in. *)

    val package : t -> string option
    (** [package t] is [t]'s package, or [None] when it has none. *)

    val location : t -> Location.t option
    (** [location t] is [t]'s declaration location, or [None] when unknown. *)

    val target : t -> string
    (** [target t] is the Dune target or alias that runs [t]. *)

    val enabled : t -> bool
    (** [enabled t] is [true] iff [t] is enabled in the current configuration.
    *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats [t] as ["name -> target"]. *)
  end

  type t
  (** A normalized project description for agent-facing tools. *)

  val make :
    ?root:Spice_workspace.Path.t ->
    ?build_context:string ->
    ?tests:Test.t list ->
    Component.t list ->
    t
  (** [make components] is a project description.

      [build_context] is the Dune build context name or path. Raises
      [Invalid_argument] if [build_context] is empty when present, or if
      [components] contains duplicate ids, any component dependency refers to a
      missing component id, or any test refers to a missing component id. *)

  val root : t -> Spice_workspace.Path.t option
  (** [root t] is the workspace root of the project, or [None] when unknown. *)

  val build_context : t -> string option
  (** [build_context t] is the Dune build context name or path, or [None] when
      unknown. *)

  val components : t -> Component.t list
  (** [components t] is all of the project's components. *)

  val tests : t -> Test.t list
  (** [tests t] is all of the project's tests. *)

  val component : t -> Component.Id.t -> Component.t option
  (** [component t id] is [Some c] if [c] is the component with id [id] in [t],
      and [None] otherwise. *)

  val dependencies : t -> Component.Id.t -> Component.t Deps.t option
  (** [dependencies t id] is [Some deps] if [id] is a component in [t] and
      [None] otherwise.

      [Some Deps.Unknown] means the producer did not compute direct dependencies
      for [id]. [Some (Deps.Known [])] means the producer computed the direct
      dependencies and found none. *)

  val local_components : t -> Component.t list
  (** [local_components t] is the project's local libraries and executables. *)

  val external_components : t -> Component.t list
  (** [external_components t] is the project's external-library components. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] as a count of its components and tests. *)
end
