(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
module Ocaml = Spice_ocaml
module Find = Ocaml_find_references
module Identity = Spice_digest.Identity
module Receipt = Receipt

let name = "ocaml_rename"
let default_program = Find.default_program
let default_max_occurrences = 200
let default_max_bytes = 1024 * 1024
let description = Spice_prompts.Tools.ocaml_rename

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

(* ------------------------------------------------------------------ *)
(* Lexical classification of identifiers                              *)
(* ------------------------------------------------------------------ *)

let is_ident_char c =
  (c >= 'a' && c <= 'z')
  || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9')
  || c = '_' || c = '\''

let is_ident_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

type name_class = Lowercase | Uppercase | Other

let classify_name value =
  if String.is_empty value then Other
  else
    match value.[0] with
    | 'a' .. 'z' | '_' -> Lowercase
    | 'A' .. 'Z' -> Uppercase
    | _ -> Other

let name_class_to_string = function
  | Lowercase -> "value"
  | Uppercase -> "constructor or module"
  | Other -> "operator"

let is_valid_identifier value =
  (not (String.is_empty value))
  && is_ident_start value.[0]
  && String.for_all is_ident_char value

let keywords =
  [
    "and";
    "as";
    "assert";
    "begin";
    "class";
    "constraint";
    "do";
    "done";
    "downto";
    "else";
    "end";
    "exception";
    "external";
    "false";
    "for";
    "fun";
    "function";
    "functor";
    "if";
    "in";
    "include";
    "inherit";
    "initializer";
    "land";
    "lazy";
    "let";
    "lor";
    "lsl";
    "lsr";
    "lxor";
    "match";
    "method";
    "mod";
    "module";
    "mutable";
    "new";
    "nonrec";
    "object";
    "of";
    "open";
    "or";
    "private";
    "rec";
    "sig";
    "struct";
    "then";
    "to";
    "true";
    "try";
    "type";
    "val";
    "virtual";
    "when";
    "while";
    "with";
  ]

let is_keyword value = List.mem value keywords

(* ------------------------------------------------------------------ *)
(* Byte offsets                                                       *)
(* ------------------------------------------------------------------ *)

let line_starts text =
  let starts = ref [ 0 ] in
  String.iteri
    (fun index char ->
      if Char.equal char '\n' then starts := (index + 1) :: !starts)
    text;
  Array.of_list (List.rev !starts)

let offset_of starts text ~line ~column =
  if line < 1 || line > Array.length starts then None
  else
    let start = starts.(line - 1) in
    let limit =
      if line = Array.length starts then String.length text
      else starts.(line) - 1
    in
    let offset = start + column in
    if offset > limit then None else Some offset

(* [identifier_at] extracts the maximal identifier token overlapping the
   cursor. Merlin reports the identifier start, but a caller may point at any
   byte inside it, so we expand both ways over identifier characters. *)
let identifier_at ~contents ~starts ~line ~column =
  match offset_of starts contents ~line ~column with
  | None -> None
  | Some offset ->
      let len = String.length contents in
      let anchor =
        if offset < len && is_ident_char contents.[offset] then Some offset
        else if offset > 0 && is_ident_char contents.[offset - 1] then
          Some (offset - 1)
        else None
      in
      Option.bind anchor (fun anchor ->
          let start = ref anchor in
          while !start > 0 && is_ident_char contents.[!start - 1] do
            decr start
          done;
          let stop = ref anchor in
          while !stop < len && is_ident_char contents.[!stop] do
            incr stop
          done;
          Some (String.sub contents !start (!stop - !start)))

(* ------------------------------------------------------------------ *)
(* Parsetree scan for pun and label sites                             *)
(* ------------------------------------------------------------------ *)

type parsed = Impl of Parsetree.structure | Intf of Parsetree.signature

let lexbuf ?(filename = "") text =
  let lexbuf = Lexing.from_string text in
  lexbuf.Lexing.lex_curr_p <-
    {
      Lexing.pos_fname = filename;
      Lexing.pos_lnum = 1;
      Lexing.pos_bol = 0;
      Lexing.pos_cnum = 0;
    };
  lexbuf

let parse ~filename ~intf contents =
  try
    if intf then Ok (Intf (Parse.interface (lexbuf ~filename contents)))
    else Ok (Impl (Parse.implementation (lexbuf ~filename contents)))
  with exn -> Error (Printexc.to_string exn)

let position_of_lexing (position : Lexing.position) =
  Ocaml.Position.make ~line:position.Lexing.pos_lnum
    ~column:(position.Lexing.pos_cnum - position.Lexing.pos_bol)

let range_of_loc_opt (loc : Location.t) =
  if
    loc.Location.loc_ghost
    || loc.Location.loc_start.Lexing.pos_cnum
       > loc.Location.loc_end.Lexing.pos_cnum
  then None
  else
    match
      Ocaml.Range.make
        ~start:(position_of_lexing loc.Location.loc_start)
        ~end_:(position_of_lexing loc.Location.loc_end)
    with
    | range -> Some range
    | exception Invalid_argument _ -> None

(* Ghost-tolerant range: punned record-field labels are synthesized by the
   parser and flagged ghost, but still carry the real source span. *)
let loc_range_lax (loc : Location.t) =
  if
    loc.Location.loc_start.Lexing.pos_cnum
    > loc.Location.loc_end.Lexing.pos_cnum
  then None
  else
    match
      Ocaml.Range.make
        ~start:(position_of_lexing loc.Location.loc_start)
        ~end_:(position_of_lexing loc.Location.loc_end)
    with
    | range -> Some range
    | exception Invalid_argument _ -> None

(* The source range of a longident's final segment: what Merlin locates for a
   dotted path [A.B.x]. Ghost-tolerant, since punned labels are ghost. *)
let longident_last_range (lid : Longident.t Location.loc) =
  match lid.Location.txt with
  | Longident.Lident _ -> loc_range_lax lid.Location.loc
  | Longident.Ldot (_, last) -> loc_range_lax last.Location.loc
  | Longident.Lapply _ -> None

(* Collect the exact ranges that must not be rewritten by a naive
   range-replace: record-field puns and labelled/optional argument puns. A
   Merlin occurrence landing on one of these is refused (v1), never guessed. *)
let refuse_ranges parsed =
  let ranges = ref [] in
  let add = function Some range -> ranges := range :: !ranges | None -> () in
  let record_field_pun lid value_range =
    (* The parser synthesizes a punned field's label and flags it ghost, while
       an explicit [{ x = e }] label is real. On a pun, refuse both the value's
       span and the field's final-segment span, since Merlin may report either
       (the variable use, or the field, for qualified puns). *)
    if lid.Location.loc.Location.loc_ghost then begin
      add value_range;
      add (longident_last_range lid)
    end
  in
  let param_pun (param : Parsetree.function_param) =
    match param.Parsetree.pparam_desc with
    | Parsetree.Pparam_val
        ((Asttypes.Labelled label | Asttypes.Optional label), _, pattern) -> (
        match pattern.Parsetree.ppat_desc with
        | Parsetree.Ppat_var var when String.equal var.Location.txt label ->
            (* [~x] / [?x] / [?(x = e)] parameter: label and bound variable
               collapse to one span. *)
            add (range_of_loc_opt var.Location.loc)
        | _ -> ())
    | Parsetree.Pparam_val (Asttypes.Nolabel, _, _) | Parsetree.Pparam_newtype _
      ->
        ()
  in
  let iterator =
    {
      Ast_iterator.default_iterator with
      Ast_iterator.expr =
        (fun self expr ->
          begin match expr.Parsetree.pexp_desc with
          | Parsetree.Pexp_record (fields, _) ->
              List.iter
                (fun (lid, value) ->
                  record_field_pun lid
                    (range_of_loc_opt value.Parsetree.pexp_loc))
                fields
          | Parsetree.Pexp_function (params, _, _) -> List.iter param_pun params
          | _ -> ()
          end;
          Ast_iterator.default_iterator.Ast_iterator.expr self expr);
      Ast_iterator.pat =
        (fun self pattern ->
          begin match pattern.Parsetree.ppat_desc with
          | Parsetree.Ppat_record (fields, _) ->
              List.iter
                (fun (lid, value) ->
                  record_field_pun lid
                    (range_of_loc_opt value.Parsetree.ppat_loc))
                fields
          | _ -> ()
          end;
          Ast_iterator.default_iterator.Ast_iterator.pat self pattern);
    }
  in
  (match parsed with
  | Impl structure -> iterator.Ast_iterator.structure iterator structure
  | Intf signature -> iterator.Ast_iterator.signature iterator signature);
  !ranges

(* ------------------------------------------------------------------ *)
(* Errors                                                             *)
(* ------------------------------------------------------------------ *)

type refusal = Invalid of string | Stale of string | Failed of string

let refusal_result = function
  | Invalid message -> Tool.Result.failed `Invalid_input message
  | Stale message -> Tool.Result.failed `Stale message
  | Failed message -> Tool.Result.failed `Failed message

(* ------------------------------------------------------------------ *)
(* Input                                                              *)
(* ------------------------------------------------------------------ *)

module Input = struct
  type t = {
    path : string;
    position : Ocaml.Position.t;
    new_name : string;
    dry_run : bool;
    max_occurrences : int;
  }

  let make ~path ~line ~column ~new_name ?(dry_run = false)
      ?(max_occurrences = default_max_occurrences) () =
    if String.is_empty path then invalid_arg "path must not be empty";
    if String.is_empty new_name then invalid_arg "new_name must not be empty";
    if max_occurrences < 1 then invalid_arg "max_occurrences must be positive";
    if max_occurrences > Find.max_limit then
      invalid_arg "max_occurrences exceeds 1000";
    let position = Ocaml.Position.make ~line ~column in
    { path; position; new_name; dry_run; max_occurrences }

  let path t = t.path
  let position t = t.position
  let new_name t = t.new_name
  let dry_run t = t.dry_run
  let max_occurrences t = t.max_occurrences
  let line t = Ocaml.Position.line t.position
  let column t = Ocaml.Position.column t.position

  let make_from_json_fields path line column new_name dry_run max_occurrences =
    let dry_run = Option.value ~default:false dry_run in
    let max_occurrences =
      Option.value ~default:default_max_occurrences max_occurrences
    in
    make ~path ~line ~column ~new_name ~dry_run ~max_occurrences ()

  let codec =
    Jsont.Object.map ~kind:"ocaml_rename input"
      (fun path line column new_name dry_run max_occurrences ->
        decode_invalid_arg (fun () ->
            make_from_json_fields path line column new_name dry_run
              max_occurrences))
    |> Jsont.Object.mem "path" Jsont.string ~enc:path
    |> Jsont.Object.mem "line" Jsont.int ~enc:line
    |> Jsont.Object.mem "column" Jsont.int ~enc:column
    |> Jsont.Object.mem "new_name" Jsont.string ~enc:new_name
    |> Jsont.Object.opt_mem "dry_run" Jsont.bool ~enc:(fun t ->
        Some (dry_run t))
    |> Jsont.Object.opt_mem "max_occurrences" Jsont.int ~enc:(fun t ->
        Some (max_occurrences t))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "path",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained absolute \
                         OCaml source file path." );
                  ] );
              ( "line",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "1-based source line of the identifier cursor." );
                  ] );
              ( "column",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 0);
                    ( "description",
                      Json.string
                        "0-based byte column in the source line, matching \
                         OCaml/Merlin locations." );
                  ] );
              ( "new_name",
                json_obj
                  [
                    ("type", Json.string "string");
                    ("minLength", Json.int 1);
                    ( "description",
                      Json.string
                        "Replacement identifier. Its lexical class (lowercase \
                         value vs uppercase constructor/module) must match the \
                         entity under the cursor." );
                  ] );
              ( "dry_run",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "When true, report the planned rename (files, per-file \
                         counts, old and new names) without writing. Defaults \
                         to false, which applies the rename." );
                  ] );
              ( "max_occurrences",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int Find.max_limit);
                    ( "description",
                      Json.string
                        "Safety cap on the number of occurrences a single \
                         rename may rewrite. Exceeding it refuses. Defaults to \
                         200." );
                  ] );
            ] );
        ( "required",
          Json.list
            [
              Json.string "path";
              Json.string "line";
              Json.string "column";
              Json.string "new_name";
            ] );
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

(* ------------------------------------------------------------------ *)
(* Plan evidence                                                      *)
(* ------------------------------------------------------------------ *)

module Target = struct
  type t = {
    path : Workspace.Path.t;
    occurrences : int;
    before_identity : Identity.t;
    after_identity : Identity.t;
  }

  let path t = t.path
  let occurrences t = t.occurrences
  let before_identity t = t.before_identity
  let after_identity t = t.after_identity
  let compare a b = Workspace.Path.compare a.path b.path

  let pp ppf t =
    Format.fprintf ppf "%s: %d occurrence(s)"
      (Workspace.Path.display t.path)
      t.occurrences
end

module Plan = struct
  type t = {
    old_name : string;
    new_name : string;
    targets : Target.t list;
    edit : Edit.t;
  }

  let old_name t = t.old_name
  let new_name t = t.new_name
  let targets t = t.targets

  let total_occurrences t =
    List.fold_left
      (fun acc target -> acc + Target.occurrences target)
      0 t.targets

  let edit t = t.edit
end

(* ------------------------------------------------------------------ *)
(* Output                                                             *)
(* ------------------------------------------------------------------ *)

module Output = struct
  type index_status = Unknown

  type t = {
    query : Input.t;
    plan : Plan.t;
    applied : bool;
    receipt : Receipt.t;
    index_status : index_status;
    backend : string;
  }

  let query t = t.query
  let plan t = t.plan
  let applied t = t.applied
  let receipt t = t.receipt
  let index_status t = t.index_status
  let backend t = t.backend
  let type_id : t Type.Id.t = Type.Id.make ()

  let target_json target =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display (Target.path target)));
        ("occurrences", Json.int (Target.occurrences target));
        ( "before_identity",
          Json.string (Identity.to_string (Target.before_identity target)) );
        ( "after_identity",
          Json.string (Identity.to_string (Target.after_identity target)) );
      ]

  let json t =
    let plan = t.plan in
    json_obj
      [
        ("old_name", Json.string (Plan.old_name plan));
        ("new_name", Json.string (Plan.new_name plan));
        ("applied", Json.bool t.applied);
        ("total_occurrences", Json.int (Plan.total_occurrences plan));
        ("files", Json.int (List.length (Plan.targets plan)));
        ("index_status", Json.string "unknown");
        ("backend", Json.string t.backend);
        ("targets", Json.list (List.map target_json (Plan.targets plan)));
      ]

  let text t =
    let plan = t.plan in
    let b = Buffer.create 256 in
    Buffer.add_string b
      (Printf.sprintf "OCaml rename: %s -> %s\n" (Plan.old_name plan)
         (Plan.new_name plan));
    Buffer.add_string b (Printf.sprintf "applied: %b\n" t.applied);
    Buffer.add_string b
      (Printf.sprintf "occurrences: %d in %d file(s)\n"
         (Plan.total_occurrences plan)
         (List.length (Plan.targets plan)));
    Buffer.add_string b "index_status: unknown\n";
    Buffer.add_string b (Printf.sprintf "backend: %s" t.backend);
    List.iter
      (fun target ->
        Buffer.add_char b '\n';
        Buffer.add_string b
          (Printf.sprintf "- %s: %d occurrence(s)"
             (Workspace.Path.display (Target.path target))
             (Target.occurrences target)))
      (Plan.targets plan);
    Buffer.contents b

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

(* ------------------------------------------------------------------ *)
(* Occurrence planning                                                *)
(* ------------------------------------------------------------------ *)

(* A single rewrite in a file: replace the byte span [start, stop) with
   [new_name]. Ranges are Merlin occurrences already checked to hold the old
   name and to be a plain (non-pun, non-label) identifier. *)
type replacement = { start : int; stop : int }

(* Group occurrence ranges by workspace path, preserving first-seen order. *)
let group_by_path references =
  let table = Hashtbl.create 8 in
  let order = ref [] in
  List.iter
    (fun reference ->
      let location = Find.Reference.location reference in
      let path = Ocaml.Location.path location in
      let range = Ocaml.Location.range location in
      let key = Workspace.Path.to_string path in
      match Hashtbl.find_opt table key with
      | Some (_, ranges) -> ranges := range :: !ranges
      | None ->
          let ranges = ref [ range ] in
          Hashtbl.replace table key (path, ranges);
          order := key :: !order)
    references;
  List.rev_map
    (fun key ->
      let path, ranges = Hashtbl.find table key in
      (path, List.rev !ranges))
    !order

let dedup_ranges ranges = List.sort_uniq Ocaml.Range.compare ranges

(* Classify one occurrence range against the current source, returning the byte
   span to rewrite or a structured refusal. *)
let classify_occurrence ~contents ~starts ~old_name ~refused ~display range =
  let line_col position =
    (Ocaml.Position.line position, Ocaml.Position.column position)
  in
  let start_line, start_col = line_col (Ocaml.Range.start range) in
  let end_line, end_col = line_col (Ocaml.Range.end_ range) in
  match
    ( offset_of starts contents ~line:start_line ~column:start_col,
      offset_of starts contents ~line:end_line ~column:end_col )
  with
  | Some start, Some stop when stop >= start && stop <= String.length contents
    ->
      let text = String.sub contents start (stop - start) in
      if not (String.equal text old_name) then
        Error
          (Stale
             (Printf.sprintf
                "%s:%d:%d no longer holds %S (found %S); rebuild the project \
                 index with dune build @ocaml-index and retry"
                display start_line start_col old_name text))
      else
        let before_ok = start = 0 || not (is_ident_char contents.[start - 1]) in
        let after_ok =
          stop = String.length contents || not (is_ident_char contents.[stop])
        in
        if not (before_ok && after_ok) then
          Error
            (Invalid
               (Printf.sprintf
                  "%s:%d:%d is not a standalone identifier; the local parse \
                   cannot corroborate the rename here, edit it manually"
                  display start_line start_col))
        else if
          start > 0 && (contents.[start - 1] = '~' || contents.[start - 1] = '?')
        then
          Error
            (Invalid
               (Printf.sprintf
                  "%s:%d:%d is a labelled-argument occurrence (~/?); v1 does \
                   not rewrite label or pun sites, edit it manually"
                  display start_line start_col))
        else if List.exists (Ocaml.Range.equal range) refused then
          Error
            (Invalid
               (Printf.sprintf
                  "%s:%d:%d is a record-field pun; v1 does not rewrite label \
                   or pun sites, edit it manually"
                  display start_line start_col))
        else Ok { start; stop }
  | _ ->
      Error
        (Invalid
           (Printf.sprintf
              "%s:%d:%d is outside the current source; the local parse cannot \
               corroborate the rename here"
              display start_line start_col))

let overlaps replacements =
  let sorted =
    List.sort (fun a b -> Int.compare a.start b.start) replacements
  in
  let rec loop = function
    | a :: (b :: _ as rest) -> if a.stop > b.start then true else loop rest
    | [] | [ _ ] -> false
  in
  loop sorted

let apply_replacements contents new_name replacements =
  let sorted =
    List.sort (fun a b -> Int.compare b.start a.start) replacements
  in
  List.fold_left
    (fun contents { start; stop } ->
      String.sub contents 0 start
      ^ new_name
      ^ String.sub contents stop (String.length contents - stop))
    contents sorted

(* A validated per-file rewrite. *)
type file_plan = { target : Target.t; edit : Edit.t }

let plan_file ~fs ~workspace ~old_name ~new_name (path, ranges) =
  let display = Workspace.Path.display path in
  match Fs.load_regular ~fs ~workspace path with
  | Error error -> Error (Failed (display ^ ": " ^ Fs.Error.message error))
  | Ok contents -> (
      let intf = Filename.check_suffix display ".mli" in
      if
        (not (Filename.check_suffix display ".ml"))
        && not (Filename.check_suffix display ".mli")
      then
        Error
          (Failed (display ^ ": not an OCaml source file, cannot rename here"))
      else
        match parse ~filename:display ~intf contents with
        | Error message ->
            Error (Failed (display ^ ": could not parse source: " ^ message))
        | Ok parsed -> (
            let refused = refuse_ranges parsed in
            let starts = line_starts contents in
            let ranges = dedup_ranges ranges in
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | range :: rest -> (
                  match
                    classify_occurrence ~contents ~starts ~old_name ~refused
                      ~display range
                  with
                  | Error refusal -> Error refusal
                  | Ok replacement -> collect (replacement :: acc) rest)
            in
            match collect [] ranges with
            | Error refusal -> Error refusal
            | Ok replacements -> (
                if overlaps replacements then
                  Error
                    (Invalid
                       (display
                      ^ ": occurrences overlap; the index may be stale or \
                         ppx-generated, edit it manually"))
                else
                  let after =
                    apply_replacements contents new_name replacements
                  in
                  let after_intf = intf in
                  match parse ~filename:display ~intf:after_intf after with
                  | Error message ->
                      Error
                        (Failed
                           (display ^ ": rename produced unparseable source: "
                          ^ message))
                  | Ok _ -> (
                      match Edit.rewrite ~path ~before:contents ~after with
                      | Error error -> Error (Failed (Edit.Error.message error))
                      | Ok edit ->
                          let target =
                            {
                              Target.path;
                              occurrences = List.length replacements;
                              before_identity = Identity.of_contents contents;
                              after_identity = Identity.of_contents after;
                            }
                          in
                          Ok { target; edit }))))

let plan_all ~fs ~workspace ~old_name ~new_name grouped =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | group :: rest -> (
        match plan_file ~fs ~workspace ~old_name ~new_name group with
        | Error refusal -> Error refusal
        | Ok file_plan -> loop (file_plan :: acc) rest)
  in
  loop [] grouped

(* ------------------------------------------------------------------ *)
(* Apply                                                              *)
(* ------------------------------------------------------------------ *)

let edit_io ~fs ~workspace ~max_bytes =
  Fs.Edit.io ~fs ~workspace ~max_bytes ~create_parent_dirs:false
    ~allow_remove:false ~remove_error:"ocaml_rename cannot delete files" ()
  |> fst

let apply_error_result ~plan_paths apply_error =
  let error = Edit.Apply_error.error apply_error in
  match error with
  | Edit.Error.Io _ ->
      let applied =
        List.map Edit.Result.Entry.target_path
          (Edit.Apply_error.applied apply_error)
      in
      let written =
        match applied with
        | [] -> "none"
        | paths -> String.concat ", " (List.map Workspace.Path.display paths)
      in
      let not_written =
        List.filter
          (fun path -> not (List.exists (Workspace.Path.equal path) applied))
          plan_paths
        |> List.map Workspace.Path.display
      in
      let not_written =
        match not_written with
        | [] -> "none"
        | paths -> String.concat ", " paths
      in
      Tool.Result.failed `Failed
        (Printf.sprintf
           "rename left a partial write after an IO fault: rewrote [%s], did \
            not rewrite [%s]. The tree is partially renamed; recover with the \
            run checkpoint."
           written not_written)
  | _ -> Edit_error.failed error

(* ------------------------------------------------------------------ *)
(* Permissions                                                        *)
(* ------------------------------------------------------------------ *)

let find_input input =
  Find.Input.make ~scope:Find.Scope.Renaming ~include_stale:false
    ~limit:(Input.max_occurrences input)
    ~path:(Input.path input) ~line:(Input.line input)
    ~column:(Input.column input) ()

let permissions ?(program = default_program) ~workspace input =
  match Find.permissions ~program ~workspace (find_input input) with
  | [] -> []
  | base when Input.dry_run input -> base
  | base ->
      let root = Workspace.root_path workspace in
      (* The real fix is per-file discovery: request [Modify] on the occurrence
         files the rename resolves to (v2), the way every other mutating tool
         does. Until then this coarse workspace-root placeholder is capped at
         once-only ([~grantable:false]): a session-scope allow must not persist a
         [Modify root] grant that would then auto-allow every future rename
         anywhere in the tree without a fresh review. *)
      base
      @ [
          Permission.Request.of_accesses ~source:name ~grantable:false
            [ Permission.Access.path ~op:`Modify root ];
        ]

(* ------------------------------------------------------------------ *)
(* Run                                                                *)
(* ------------------------------------------------------------------ *)

let interrupted () =
  Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()

let validate_new_name ~old_name ~new_name =
  let old_class = classify_name old_name in
  let new_class = classify_name new_name in
  if old_class = Other then
    Error
      (Invalid
         (Printf.sprintf
            "the entity under the cursor (%S) is an operator or unsupported \
             identifier; rename supports value and constructor/module names \
             only"
            old_name))
  else if not (is_valid_identifier new_name) then
    Error
      (Invalid
         (Printf.sprintf "new name %S is not a valid OCaml identifier" new_name))
  else if is_keyword new_name then
    Error (Invalid (Printf.sprintf "new name %S is an OCaml keyword" new_name))
  else if new_class <> old_class then
    Error
      (Invalid
         (Printf.sprintf
            "new name %S is a %s identifier but the entity is a %s identifier"
            new_name
            (name_class_to_string new_class)
            (name_class_to_string old_class)))
  else if String.equal new_name old_name then
    Error
      (Invalid
         (Printf.sprintf "new name %S is the same as the current name" new_name))
  else Ok ()

let build_output ~input ~old_name ~new_name ~file_plans ~applied ~receipt =
  let targets =
    List.map (fun fp -> fp.target) file_plans |> List.sort Target.compare
  in
  match Edit.concat (List.map (fun fp -> fp.edit) file_plans) with
  | Error error -> Error (Failed (Edit.Error.message error))
  | Ok edit ->
      let plan = { Plan.old_name; new_name; targets; edit } in
      Ok
        {
          Output.query = input;
          plan;
          applied;
          receipt;
          index_status = Output.Unknown;
          backend = "ocamlmerlin";
        }

let finish_output ~input ~old_name ~new_name ~file_plans ~applied ~receipt =
  match
    build_output ~input ~old_name ~new_name ~file_plans ~applied ~receipt
  with
  | Error refusal -> refusal_result refusal
  | Ok output -> Tool.Result.completed ~output ()

let commit ~fs ~workspace ~input ~old_name ~new_name ~file_plans =
  let plan_paths = List.map (fun fp -> fp.target.Target.path) file_plans in
  match Edit.concat (List.map (fun fp -> fp.edit) file_plans) with
  | Error error -> Tool.Result.failed `Failed (Edit.Error.message error)
  | Ok combined -> (
      if Edit.is_empty combined then
        finish_output ~input ~old_name ~new_name ~file_plans ~applied:true
          ~receipt:Receipt.empty
      else
        let io = edit_io ~fs ~workspace ~max_bytes:default_max_bytes in
        match Edit.apply ~io ~workspace combined with
        | Error apply_error -> apply_error_result ~plan_paths apply_error
        | Ok result ->
            finish_output ~input ~old_name ~new_name ~file_plans ~applied:true
              ~receipt:(Receipt.make result))

let run_resolved ~sandbox ~program ~fs ~workspace ctx input old_name =
  let new_name = Input.new_name input in
  let sub = Find.run ~sandbox ~program ~fs ~workspace ctx (find_input input) in
  match Tool.Result.status sub with
  | Tool.Result.Interrupted { reason; cancelled } ->
      Tool.Result.interrupted ~reason ~cancelled ()
  | Tool.Result.Failed { kind; message; _ } -> Tool.Result.failed kind message
  | Tool.Result.Completed -> (
      match Tool.Result.output sub with
      | None ->
          Tool.Result.failed `Failed "find_references completed without output"
      | Some fout -> (
          if Find.Output.stale_skipped fout > 0 then
            Tool.Result.failed `Stale
              (Printf.sprintf
                 "index appears stale: %d occurrence(s) skipped; rebuild with \
                  dune build @ocaml-index and retry"
                 (Find.Output.stale_skipped fout))
          else if Find.Output.has_more fout then
            Tool.Result.failed `Failed
              (Printf.sprintf
                 "%d occurrences exceed the rename cap %d; the rename is too \
                  large to apply safely as one edit"
                 (Find.Output.total_count fout)
                 (Input.max_occurrences input))
          else
            match Find.Output.references fout with
            | [] ->
                Tool.Result.failed `Invalid_input
                  (Printf.sprintf
                     "no renameable binding at %s:%d:%d; the cursor may not be \
                      on an identifier, or the project index is missing (dune \
                      build @ocaml-index)"
                     (Input.path input) (Input.line input) (Input.column input))
            | references -> (
                let grouped = group_by_path references in
                match plan_all ~fs ~workspace ~old_name ~new_name grouped with
                | Error refusal -> refusal_result refusal
                | Ok file_plans ->
                    if Tool.Context.cancelled ctx then interrupted ()
                    else if Input.dry_run input then
                      finish_output ~input ~old_name ~new_name ~file_plans
                        ~applied:false ~receipt:Receipt.empty
                    else
                      commit ~fs ~workspace ~input ~old_name ~new_name
                        ~file_plans)))

let run ~sandbox ?(program = default_program) ~fs ~workspace ctx input =
  if Tool.Context.cancelled ctx then interrupted ()
  else
    match Workspace.resolve_string workspace (Input.path input) with
    | Error error ->
        Tool.Result.failed `Invalid_input
          (Workspace.Resolve_error.message error)
    | Ok query_path -> (
        match Fs.load_regular ~fs ~workspace query_path with
        | Error error -> Fs_error.failed ~message:(Fs.Error.message error) error
        | Ok contents -> (
            let starts = line_starts contents in
            match
              identifier_at ~contents ~starts ~line:(Input.line input)
                ~column:(Input.column input)
            with
            | None ->
                Tool.Result.failed `Invalid_input
                  (Printf.sprintf
                     "no identifier at %s:%d:%d; place the cursor on the \
                      binding to rename"
                     (Workspace.Path.display query_path)
                     (Input.line input) (Input.column input))
            | Some old_name -> (
                match
                  validate_new_name ~old_name ~new_name:(Input.new_name input)
                with
                | Error refusal -> refusal_result refusal
                | Ok () ->
                    run_resolved ~sandbox ~program ~fs ~workspace ctx input old_name)))

let tool ~sandbox ?program ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ?program ~workspace input)
    ~run:(run ~sandbox ?program ~fs ~workspace)
    ()
