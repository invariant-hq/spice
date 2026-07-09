(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid m fn message = invalid_arg (m ^ "." ^ fn ^ ": " ^ message)

let require_non_empty m fn field = function
  | "" -> invalid m fn (field ^ " must not be empty")
  | _ -> ()

let has_duplicates compare values =
  let sorted = List.sort compare values in
  let rec loop = function
    | first :: (second :: _ as rest) -> compare first second = 0 || loop rest
    | [] | [ _ ] -> false
  in
  loop sorted

let source_label label =
  let valid_char = function
    | 'a' .. 'z' | '0' .. '9' | '-' -> true
    | _ -> false
  in
  (not (String.is_empty label))
  && String.for_all valid_char label
  && (not (String.starts_with ~prefix:"-" label))
  && (not (String.ends_with ~suffix:"-" label))
  && not (String.contains label '\000')

let plain_label label =
  (not (String.is_empty label)) && not (String.contains label '\000')

let module_name_label label =
  let valid_rest = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '\'' -> true
    | _ -> false
  in
  let rec loop i =
    if i = String.length label then true
    else valid_rest label.[i] && loop (i + 1)
  in
  String.length label > 0
  && match label.[0] with 'A' .. 'Z' -> loop 1 | _ -> false

module Position = struct
  type t = { line : int; column : int }

  let make ~line ~column =
    if line < 1 then invalid "Spice_ocaml.Position" "make" "line must be >= 1";
    if column < 0 then
      invalid "Spice_ocaml.Position" "make" "column must be >= 0";
    { line; column }

  let line t = t.line
  let column t = t.column

  let compare a b =
    match Int.compare a.line b.line with
    | 0 -> Int.compare a.column b.column
    | order -> order

  let equal a b = Int.equal a.line b.line && Int.equal a.column b.column
  let pp ppf t = Format.fprintf ppf "%d:%d" t.line t.column
end

module Range = struct
  type t = { start : Position.t; end_ : Position.t }

  let make ~start ~end_ =
    if Position.compare end_ start < 0 then
      invalid "Spice_ocaml.Range" "make" "end_ must not be before start";
    { start; end_ }

  let point position = make ~start:position ~end_:position
  let start t = t.start
  let end_ t = t.end_

  let contains ~outer t =
    Position.compare outer.start t.start <= 0
    && Position.compare t.end_ outer.end_ <= 0

  let compare a b =
    match Position.compare a.start b.start with
    | 0 -> Position.compare a.end_ b.end_
    | order -> order

  let equal a b = Position.equal a.start b.start && Position.equal a.end_ b.end_

  let pp ppf t =
    Format.fprintf ppf "%a-%a" Position.pp t.start Position.pp t.end_
end

module Location = struct
  type t = { path : Spice_workspace.Path.t; range : Range.t }

  let make ~path ~range = { path; range }
  let path t = t.path
  let range t = t.range
  let start t = Range.start t.range
  let end_ t = Range.end_ t.range

  let compare a b =
    match Spice_workspace.Path.compare a.path b.path with
    | 0 -> Range.compare a.range b.range
    | order -> order

  let pp ppf t =
    Format.fprintf ppf "%s:%a"
      (Spice_workspace.Path.display t.path)
      Range.pp t.range
end

module Module_name = struct
  type t = string

  let make name =
    if not (module_name_label name) then
      invalid "Spice_ocaml.Module_name" "make"
        "name must be an OCaml module name";
    name

  let to_string t = t
  let compare = String.compare
  let pp ppf t = Format.pp_print_string ppf t
end

module Diagnostic = struct
  module Severity = struct
    type t = Error | Warning | Information | Hint

    let rank (severity : t) =
      match severity with
      | Error -> 0
      | Warning -> 1
      | Information -> 2
      | Hint -> 3

    let compare a b = Int.compare (rank a) (rank b)
    let equal a b = compare a b = 0

    let pp ppf (severity : t) =
      match severity with
      | Error -> Format.pp_print_string ppf "error"
      | Warning -> Format.pp_print_string ppf "warning"
      | Information -> Format.pp_print_string ppf "information"
      | Hint -> Format.pp_print_string ppf "hint"
  end

  module Source = struct
    type t = Dune | Merlin | Compiler | Ocamlformat | Odoc | Other of string

    let to_string = function
      | Dune -> "dune"
      | Merlin -> "merlin"
      | Compiler -> "compiler"
      | Ocamlformat -> "ocamlformat"
      | Odoc -> "odoc"
      | Other label -> label

    let builtins = [ Dune; Merlin; Compiler; Ocamlformat; Odoc ]
    let dune = Dune
    let merlin = Merlin
    let compiler = Compiler
    let ocamlformat = Ocamlformat
    let odoc = Odoc

    let other label =
      if not (source_label label) then
        invalid "Spice_ocaml.Diagnostic.Source" "other"
          "label must be lowercase ASCII words separated by hyphens";
      if
        List.exists
          (fun source -> String.equal label (to_string source))
          builtins
      then
        invalid "Spice_ocaml.Diagnostic.Source" "other"
          "label must not collide with a built-in source";
      Other label

    let rank = function
      | Dune -> 0
      | Merlin -> 1
      | Compiler -> 2
      | Ocamlformat -> 3
      | Odoc -> 4
      | Other _ -> 5

    let compare a b =
      match Int.compare (rank a) (rank b) with
      | 0 -> String.compare (to_string a) (to_string b)
      | order -> order

    let equal a b = compare a b = 0
    let pp ppf t = Format.pp_print_string ppf (to_string t)
  end

  module Tag = struct
    type t = Unnecessary | Deprecated

    let rank = function Unnecessary -> 0 | Deprecated -> 1
    let compare a b = Int.compare (rank a) (rank b)
    let equal a b = compare a b = 0

    let pp ppf = function
      | Unnecessary -> Format.pp_print_string ppf "unnecessary"
      | Deprecated -> Format.pp_print_string ppf "deprecated"
  end

  module Related = struct
    type t = { message : string; location : Location.t option }

    let make ?location message =
      require_non_empty "Spice_ocaml.Diagnostic.Related" "make" "message"
        message;
      { message; location }

    let message t = t.message
    let location t = t.location

    let compare a b =
      match Option.compare Location.compare a.location b.location with
      | 0 -> String.compare a.message b.message
      | order -> order

    let pp ppf t =
      match t.location with
      | None -> Format.pp_print_string ppf t.message
      | Some location ->
          Format.fprintf ppf "%a: %s" Location.pp location t.message
  end

  type t = {
    message : string;
    source : Source.t;
    severity : Severity.t;
    location : Location.t option;
    code : string option;
    tags : Tag.t list;
    related : Related.t list;
  }

  let duplicate_tag tags =
    let rec loop seen = function
      | [] -> false
      | tag :: rest ->
          List.exists (Tag.equal tag) seen || loop (tag :: seen) rest
    in
    loop [] tags

  let make ?location ?code ?(tags = []) ?(related = []) ~source ~severity
      message =
    require_non_empty "Spice_ocaml.Diagnostic" "make" "message" message;
    Option.iter (require_non_empty "Spice_ocaml.Diagnostic" "make" "code") code;
    if duplicate_tag tags then
      invalid "Spice_ocaml.Diagnostic" "make" "tags must not contain duplicates";
    { message; source; severity; location; code; tags; related }

  let message t = t.message
  let source t = t.source
  let severity t = t.severity
  let location t = t.location
  let code t = t.code
  let tags t = t.tags
  let related t = t.related

  let compare a b =
    match Option.compare Location.compare a.location b.location with
    | 0 -> (
        match Source.compare a.source b.source with
        | 0 -> (
            match Severity.compare a.severity b.severity with
            | 0 -> (
                match Option.compare String.compare a.code b.code with
                | 0 -> (
                    match String.compare a.message b.message with
                    | 0 -> (
                        match List.compare Tag.compare a.tags b.tags with
                        | 0 -> List.compare Related.compare a.related b.related
                        | order -> order)
                    | order -> order)
                | order -> order)
            | order -> order)
        | order -> order)
    | order -> order

  let equal a b = compare a b = 0

  let pp ppf t =
    match t.location with
    | None ->
        Format.fprintf ppf "%a[%a]: %s" Source.pp t.source Severity.pp
          t.severity t.message
    | Some location ->
        Format.fprintf ppf "%a: %a[%a]: %s" Location.pp location Source.pp
          t.source Severity.pp t.severity t.message
end

module Project = struct
  module Deps = struct
    type 'a t = Unknown | Known of 'a list

    let unknown = Unknown
    let known values = Known values
  end

  module Compilation_unit = struct
    type t = {
      name : Module_name.t;
      impl : Spice_workspace.Path.t option;
      intf : Spice_workspace.Path.t option;
      interface_deps : Module_name.t Deps.t;
      implementation_deps : Module_name.t Deps.t;
    }

    let check_unique_deps fn field deps =
      match deps with
      | Deps.Unknown -> ()
      | Deps.Known deps ->
          if has_duplicates Module_name.compare deps then
            invalid "Spice_ocaml.Project.Compilation_unit" fn
              (field ^ " must not contain duplicates")

    let make ?impl ?intf ?(interface_deps = Deps.Unknown)
        ?(implementation_deps = Deps.Unknown) name =
      check_unique_deps "make" "interface_deps" interface_deps;
      check_unique_deps "make" "implementation_deps" implementation_deps;
      { name; impl; intf; interface_deps; implementation_deps }

    let name t = t.name
    let impl t = t.impl
    let intf t = t.intf
    let interface_deps t = t.interface_deps
    let implementation_deps t = t.implementation_deps
    let pp ppf t = Module_name.pp ppf t.name
  end

  module Component = struct
    module Id = struct
      type t = string

      let check_name fn field value =
        if not (plain_label value) then
          invalid "Spice_ocaml.Project.Component.Id" fn
            (field ^ " must not be empty or contain NUL")

      let library name =
        check_name "library" "name" name;
        "library:" ^ name

      let external_library name =
        check_name "external_library" "name" name;
        "external-library:" ^ name

      let executable ~dir ~name =
        check_name "executable" "name" name;
        "executable:" ^ Spice_workspace.Path.to_string dir ^ ":" ^ name

      let to_string t = t
      let compare = String.compare
      let equal = String.equal
      let pp ppf t = Format.pp_print_string ppf t
    end

    module Kind = struct
      type t = Local_library | External_library | Executable

      let pp ppf = function
        | Local_library -> Format.pp_print_string ppf "library"
        | External_library -> Format.pp_print_string ppf "external-library"
        | Executable -> Format.pp_print_string ppf "executable"
    end

    type t = {
      id : Id.t;
      name : string;
      kind : Kind.t;
      source_dir : Spice_workspace.Path.t option;
      location : Location.t option;
      units : Compilation_unit.t list;
      requires : Id.t Deps.t;
    }

    let check_requires fn = function
      | Deps.Unknown -> ()
      | Deps.Known requires ->
          if has_duplicates Id.compare requires then
            invalid "Spice_ocaml.Project.Component" fn
              "requires must not contain duplicate ids"

    let make ?source_dir ?location ?(units = []) ?(requires = Deps.Unknown) ~id
        ~name ~kind () =
      require_non_empty "Spice_ocaml.Project.Component" "make" "name" name;
      check_requires "make" requires;
      { id; name; kind; source_dir; location; units; requires }

    let local_library ?source_dir ?location ?units ?requires ~name () =
      make ?source_dir ?location ?units ?requires ~id:(Id.library name) ~name
        ~kind:Kind.Local_library ()

    let external_library ?source_dir ?location ?units ?requires ~name () =
      make ?source_dir ?location ?units ?requires ~id:(Id.external_library name)
        ~name ~kind:Kind.External_library ()

    let executable ~dir ?location ?units ?requires ~name () =
      make ~source_dir:dir ?location ?units ?requires
        ~id:(Id.executable ~dir ~name) ~name ~kind:Kind.Executable ()

    let with_requires requires t =
      check_requires "with_requires" requires;
      { t with requires }

    let id t = t.id
    let name t = t.name
    let kind t = t.kind
    let source_dir t = t.source_dir
    let location t = t.location
    let units t = t.units
    let requires t = t.requires
    let pp ppf t = Format.fprintf ppf "%a %s" Kind.pp t.kind t.name
  end

  module Test = struct
    type t = {
      component : Component.Id.t option;
      name : string;
      source_dir : Spice_workspace.Path.t;
      package : string option;
      location : Location.t option;
      target : string;
      enabled : bool;
    }

    let make ?component ?package ?location ~name ~source_dir ~target ~enabled ()
        =
      require_non_empty "Spice_ocaml.Project.Test" "make" "name" name;
      Option.iter
        (require_non_empty "Spice_ocaml.Project.Test" "make" "package")
        package;
      require_non_empty "Spice_ocaml.Project.Test" "make" "target" target;
      { component; name; source_dir; package; location; target; enabled }

    let component t = t.component
    let name t = t.name
    let source_dir t = t.source_dir
    let package t = t.package
    let location t = t.location
    let target t = t.target
    let enabled t = t.enabled
    let pp ppf t = Format.fprintf ppf "%s -> %s" t.name t.target
  end

  type t = {
    root : Spice_workspace.Path.t option;
    build_context : string option;
    components : Component.t list;
    tests : Test.t list;
  }

  let make ?root ?build_context ?(tests = []) components =
    Option.iter
      (require_non_empty "Spice_ocaml.Project" "make" "build_context")
      build_context;
    let component_ids = List.map Component.id components in
    if has_duplicates Component.Id.compare component_ids then
      invalid "Spice_ocaml.Project" "make"
        "components must not contain duplicate ids";
    let has_component id =
      List.exists
        (fun component -> Component.Id.equal id (Component.id component))
        components
    in
    List.iter
      (fun component ->
        match Component.requires component with
        | Deps.Unknown -> ()
        | Deps.Known requires ->
            List.iter
              (fun id ->
                if not (has_component id) then
                  invalid "Spice_ocaml.Project" "make"
                    "component requires unknown component id")
              requires)
      components;
    List.iter
      (fun test ->
        match Test.component test with
        | None -> ()
        | Some id ->
            if not (has_component id) then
              invalid "Spice_ocaml.Project" "make"
                "test references unknown component id")
      tests;
    { root; build_context; components; tests }

  let root t = t.root
  let build_context t = t.build_context
  let components t = t.components
  let tests t = t.tests

  let component t id =
    List.find_opt
      (fun component -> Component.Id.equal id (Component.id component))
      t.components

  let filter_known_components t ids = List.filter_map (component t) ids

  let dependencies t id =
    match component t id with
    | None -> None
    | Some component -> (
        match Component.requires component with
        | Deps.Unknown -> Some Deps.Unknown
        | Deps.Known ids -> Some (Deps.Known (filter_known_components t ids)))

  let local_components t =
    List.filter
      (fun component ->
        match Component.kind component with
        | Component.Kind.Local_library | Component.Kind.Executable -> true
        | Component.Kind.External_library -> false)
      t.components

  let external_components t =
    List.filter
      (fun component ->
        match Component.kind component with
        | Component.Kind.External_library -> true
        | Component.Kind.Local_library | Component.Kind.Executable -> false)
      t.components

  let pp ppf t =
    Format.fprintf ppf "%d components, %d tests" (List.length t.components)
      (List.length t.tests)
end
