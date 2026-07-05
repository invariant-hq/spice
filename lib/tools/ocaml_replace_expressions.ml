(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import
open Parsetree
open Longident
open Asttypes
open Ast_iterator
module Ocaml = Spice_ocaml
module Grep = Spice_ocaml_grep

let name = "ocaml_replace_expressions"
let default_max_sites = 200
let max_max_sites = 1_000
let max_source_bytes = 8 * 1024 * 1024
let max_excerpt_bytes = 2_000
let description = Spice_prompts.Tools.ocaml_replace_expressions

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

(* Metavariables are __ followed by one or more digits, mirroring
   {!Spice_ocaml_grep}'s private predicate: the engine does not expose it, so
   this tool replicates the grammar exactly. Any change to the engine grammar
   must be reflected here. *)
let is_metavar str =
  String.length str > 2
  && str.[0] = '_'
  && str.[1] = '_'
  &&
  let all_digits = ref true in
  for i = 2 to String.length str - 1 do
    match str.[i] with '0' .. '9' -> () | _ -> all_digits := false
  done;
  !all_digits

(* {1 Pure template parsing and validation} *)

let parse_expr text =
  match Parse.expression (Lexing.from_string text) with
  | expr -> Some expr
  | exception _ -> None

let parse_expr_diag text =
  match Parse.expression (Lexing.from_string text) with
  | expr -> Ok expr
  | exception exn ->
      let position =
        match exn with
        | Syntaxerr.Error error ->
            let loc = Syntaxerr.location_of_error error in
            let start = loc.Location.loc_start in
            Printf.sprintf " at line %d, column %d" start.Lexing.pos_lnum
              (start.Lexing.pos_cnum - start.Lexing.pos_bol)
        | _ -> ""
      in
      Error (Printf.sprintf "not a single OCaml expression%s" position)

(* Every metavariable occurring anywhere in an expression pattern or template,
   in every longident, pattern-variable, and constructor position. Used for the
   subset gate. *)
let collect_metavars ast =
  let acc = ref [] in
  let add s = if is_metavar s && not (List.mem s !acc) then acc := s :: !acc in
  let rec lident = function
    | Lident s -> add s
    | Ldot (l, s) ->
        lident l.Location.txt;
        add s.Location.txt
    | Lapply (a, b) ->
        lident a.Location.txt;
        lident b.Location.txt
  in
  let super = Ast_iterator.default_iterator in
  let expr self e =
    (match e.pexp_desc with
    | Pexp_ident { txt; _ } | Pexp_new { txt; _ } -> lident txt
    | Pexp_construct ({ txt; _ }, _) -> lident txt
    | Pexp_field (_, { txt; _ }) | Pexp_setfield (_, { txt; _ }, _) ->
        lident txt
    | _ -> ());
    super.expr self e
  in
  let pat self p =
    (match p.ppat_desc with
    | Ppat_var { txt; _ } -> add txt
    | Ppat_construct ({ txt; _ }, _) -> lident txt
    | _ -> ());
    super.pat self p
  in
  let it = { super with expr; pat } in
  it.expr it ast;
  List.sort compare !acc

(* Expression-position holes of a template, with their byte ranges in the
   (trimmed) template source. Locations are compiler locations whose [pos_cnum]
   is the byte offset from the template start. *)
let template_holes ast =
  let acc = ref [] in
  let super = Ast_iterator.default_iterator in
  let expr self e =
    match e.pexp_desc with
    | Pexp_ident { txt = Lident s; _ } when is_metavar s ->
        acc := (s, e.pexp_loc) :: !acc
    | _ -> super.expr self e
  in
  let it = { super with expr } in
  it.expr it ast;
  List.rev !acc

(* Pattern-only vocabulary is meaningless in a template: [__] would splice
   nothing and [PRESENT]/[MISSING] would render as literal constructors. *)
let forbidden_vocabulary ast =
  let found = ref None in
  let set message = if !found = None then found := Some message in
  let rec lident = function
    | Lident "__" ->
        set
          "the anonymous wildcard __ is pattern-only; a template needs a \
           numbered hole like __1"
    | Lident _ -> ()
    | Ldot (l, s) ->
        lident l.Location.txt;
        if String.equal s.Location.txt "__" then
          set "the anonymous wildcard __ is pattern-only in a template"
    | Lapply (a, b) ->
        lident a.Location.txt;
        lident b.Location.txt
  in
  let super = Ast_iterator.default_iterator in
  let expr self e =
    (match e.pexp_desc with
    | Pexp_ident { txt; _ } -> lident txt
    | Pexp_construct
        ({ txt = Lident (("PRESENT" | "MISSING") as marker); _ }, None) ->
        set
          (marker
         ^ " is a pattern-only optional-argument marker and has no meaning in \
            a template")
    | _ -> ());
    super.expr self e
  in
  let pat self p =
    (match p.ppat_desc with
    | Ppat_var { txt = "__"; _ } -> set "the wildcard __ is pattern-only"
    | _ -> ());
    super.pat self p
  in
  let it = { super with expr; pat } in
  it.expr it ast;
  !found

let pattern_vars p =
  let acc = ref [] in
  let super = Ast_iterator.default_iterator in
  let pat self pp =
    (match pp.ppat_desc with
    | Ppat_var { txt; _ } -> acc := txt :: !acc
    | Ppat_alias (_, { txt; _ }) -> acc := txt :: !acc
    | _ -> ());
    super.pat self pp
  in
  let it = { super with pat } in
  it.pat it p;
  List.rev !acc

let param_vars (prm : function_param) =
  match prm.pparam_desc with
  | Pparam_val (_, _, p) -> pattern_vars p
  | Pparam_newtype _ -> []

(* A binder scope the template itself introduces: a body sub-expression that
   evaluates under a value binder. [Pexp_let] right-hand sides are excluded for
   a non-recursive let (they evaluate in the enclosing scope), so a hole there
   is safe. *)
type scope = { s_loc : Location.t; s_kind : string; s_binders : string list }

let template_scopes ast =
  let scopes = ref [] in
  let add loc kind binders =
    if binders <> [] then
      scopes := { s_loc = loc; s_kind = kind; s_binders = binders } :: !scopes
  in
  let super = Ast_iterator.default_iterator in
  let expr self e =
    (match e.pexp_desc with
    | Pexp_let (rf, vbs, body) ->
        let binders = List.concat_map (fun vb -> pattern_vars vb.pvb_pat) vbs in
        add body.pexp_loc "let" binders;
        if rf = Recursive then
          List.iter (fun vb -> add vb.pvb_expr.pexp_loc "let rec" binders) vbs
    | Pexp_function (params, _, body) ->
        let binders = List.concat_map param_vars params in
        let body_loc =
          match body with
          | Pfunction_body b -> b.pexp_loc
          | Pfunction_cases (_, loc, _) -> loc
        in
        add body_loc "fun" binders
    | Pexp_match (_, cases) | Pexp_try (_, cases) ->
        List.iter
          (fun c ->
            let binders = pattern_vars c.pc_lhs in
            add c.pc_rhs.pexp_loc "match/case" binders;
            Option.iter
              (fun g -> add g.pexp_loc "match/case" binders)
              c.pc_guard)
          cases
    | Pexp_for (p, _, _, _, body) -> add body.pexp_loc "for" (pattern_vars p)
    | Pexp_struct_item (_, body) ->
        (* [let open]/[let module]/[let exception] in expression: the local
           definition can shadow a fragment's free name, so its continuation is
           a capture-risky scope. *)
        scopes :=
          {
            s_loc = body.pexp_loc;
            s_kind = "local definition";
            s_binders = [ "local binding" ];
          }
          :: !scopes
    | Pexp_letop { let_; ands; body } ->
        let binders =
          pattern_vars let_.pbop_pat
          @ List.concat_map (fun a -> pattern_vars a.pbop_pat) ands
        in
        add body.pexp_loc "binding operator" binders
    | _ -> ());
    super.expr self e
  in
  let it = { super with expr } in
  it.expr it ast;
  !scopes

let capture_offenders ast =
  let scopes = template_scopes ast in
  let contains outer inner =
    outer.Location.loc_start.Lexing.pos_cnum
    <= inner.Location.loc_start.Lexing.pos_cnum
    && inner.Location.loc_end.Lexing.pos_cnum
       <= outer.Location.loc_end.Lexing.pos_cnum
  in
  template_holes ast
  |> List.filter_map (fun (hole, hloc) ->
      match List.find_opt (fun s -> contains s.s_loc hloc) scopes with
      | Some scope -> Some (hole, scope)
      | None -> None)

(* [validate_template ~pattern_metavars raw] parses and gates [raw] purely,
   before any file is touched. Returns the trimmed template source, its parsed
   AST, and its holes. *)
let validate_template ~pattern_metavars raw =
  let template = String.trim raw in
  match parse_expr_diag template with
  | Error message -> Error ("template is " ^ message)
  | Ok ast -> (
      match forbidden_vocabulary ast with
      | Some message -> Error message
      | None -> (
          let tvars = collect_metavars ast in
          let missing =
            List.filter (fun v -> not (List.mem v pattern_metavars)) tvars
          in
          if missing <> [] then
            Error
              (Printf.sprintf
                 "template uses metavariable(s) %s that the pattern does not \
                  bind"
                 (String.concat ", " missing))
          else
            match capture_offenders ast with
            | (hole, scope) :: _ ->
                Error
                  (Printf.sprintf
                     "template hole %s is in the scope of a %s binder (%s), \
                      which risks variable capture; keep template holes \
                      outside any binder the template introduces"
                     hole scope.s_kind
                     (String.concat ", " scope.s_binders))
            | [] -> Ok (template, ast, template_holes ast)))

(* {1 Byte-offset helpers} *)

let line_starts source =
  let starts = ref [ 0 ] in
  String.iteri
    (fun i c -> if Char.equal c '\n' then starts := (i + 1) :: !starts)
    source;
  Array.of_list (List.rev !starts)

let byte_offset starts position =
  starts.(Ocaml.Position.line position - 1) + Ocaml.Position.column position

let range_bytes starts range =
  ( byte_offset starts (Ocaml.Range.start range),
    byte_offset starts (Ocaml.Range.end_ range) )

let slice source start_offset end_offset =
  String.sub source start_offset (end_offset - start_offset)

(* Highest-offset-first splice of disjoint substitutions, so lower offsets stay
   valid as we fold. *)
let splice text subs =
  let sorted =
    List.sort (fun (s1, _, _) (s2, _, _) -> Int.compare s2 s1) subs
  in
  List.fold_left
    (fun acc (start_offset, end_offset, replacement) ->
      slice acc 0 start_offset ^ replacement
      ^ slice acc end_offset (String.length acc))
    text sorted

let contains_substring hay needle =
  let n = String.length needle and h = String.length hay in
  let rec loop i =
    if i + n > h then false
    else if String.equal (String.sub hay i n) needle then true
    else loop (i + 1)
  in
  loop 0

(* {1 Rendering and per-site correctness} *)

type render_mode = Minimal | Widened

(* One captured metavariable at a site: its verbatim source bytes, its stripped
   fragment (for the expected-AST target), and whether it is a self-delimiting
   atom (an identifier or a non-signed constant) that never needs parentheses. *)
type frag = { fr_raw : string; fr_ast : Parsetree.expression; fr_atomic : bool }

(* A leading sign makes a constant non-atomic: [-1] spliced bare as an
   application argument reparses as a binary minus. *)
let is_atomic raw ast =
  match ast.pexp_desc with
  | Pexp_ident _ -> true
  | Pexp_constant _ ->
      let t = String.trim raw in
      not (String.length t > 0 && (t.[0] = '-' || t.[0] = '+'))
  | _ -> false

(* Render a template with each hole spliced with its site fragment. [Minimal]
   splices raw bytes; [Widened] wraps every fragment that is not already a
   self-delimiting atom, so the template's operators see atomic operands.
   Fragments carrying an attribute are always wrapped so the attribute cannot
   re-attach. Wrapping an already-atomic or already-parenthesized fragment is
   harmless: parens are not a Parsetree node, so the strip-equality is
   unaffected. *)
let render template holes frags mode =
  let subs =
    List.map
      (fun (hole, hloc) ->
        let frag = List.assoc hole frags in
        let raw = frag.fr_raw in
        let has_attr = contains_substring raw "[@" in
        let wrap =
          has_attr
          || match mode with Widened -> not frag.fr_atomic | Minimal -> false
        in
        let text = if wrap then "(" ^ raw ^ ")" else raw in
        ( hloc.Location.loc_start.Lexing.pos_cnum,
          hloc.Location.loc_end.Lexing.pos_cnum,
          text ))
      holes
  in
  splice template subs

(* The template with each hole replaced by the site fragment's stripped AST:
   the structural target the rewritten site must strip-equal. *)
let expected_ast template_ast frags =
  let super = Ast_mapper.default_mapper in
  let expr self e =
    match e.pexp_desc with
    | Pexp_ident { txt = Lident s; _ } when is_metavar s -> (
        match List.assoc_opt s frags with
        | Some frag -> frag.fr_ast
        | None -> super.Ast_mapper.expr self e)
    | _ -> super.Ast_mapper.expr self e
  in
  let mapper = { super with Ast_mapper.expr } in
  Grep.strip_expr (mapper.Ast_mapper.expr mapper template_ast)

let isolation_ok replacement expected =
  match parse_expr replacement with
  | Some e -> Grep.strip_expr e = expected
  | None -> false

(* Collect every expression node of a parsed structure with its byte span, for
   exact-range lookup during the whole-file post-check. *)
let expr_spans structure =
  let acc = ref [] in
  let super = Ast_iterator.default_iterator in
  let expr self e =
    acc :=
      ( e.pexp_loc.Location.loc_start.Lexing.pos_cnum,
        e.pexp_loc.Location.loc_end.Lexing.pos_cnum,
        e )
      :: !acc;
    super.expr self e
  in
  let it = { super with expr } in
  it.structure it structure;
  !acc

let node_at spans start_offset end_offset =
  List.find_map
    (fun (s, e, node) ->
      if s = start_offset && e = end_offset then Some node else None)
    spans

type site = {
  st_start : int; (* byte range of the match in the file *)
  st_end : int;
  st_before : string;
  st_expected : Parsetree.expression;
  st_location : Ocaml.Location.t;
  mutable st_text : string;
  mutable st_wrapped : bool;
}

(* Bottom-up splice of all sites into the file. *)
let apply_sites source sites =
  splice source (List.map (fun s -> (s.st_start, s.st_end, s.st_text)) sites)

(* Each site's byte range in the spliced file, tracking the running offset
   delta introduced by earlier sites (sites are ordered ascending). *)
let final_ranges sites =
  let rec loop delta = function
    | [] -> []
    | s :: rest ->
        let fstart = s.st_start + delta in
        let fend = fstart + String.length s.st_text in
        (s, fstart, fend)
        :: loop (delta + String.length s.st_text - (s.st_end - s.st_start)) rest
  in
  loop 0 sites

let build_frags site_texts =
  List.fold_left
    (fun acc (hole, raw) ->
      match acc with
      | Error _ -> acc
      | Ok frags -> (
          match parse_expr raw with
          | Some e ->
              Ok
                (( hole,
                   {
                     fr_raw = raw;
                     fr_ast = Grep.strip_expr e;
                     fr_atomic = is_atomic raw e;
                   } )
                :: frags)
          | None -> Error hole))
    (Ok []) site_texts

let site_text_of source starts binding =
  match Grep.Binding.captured binding with
  | Grep.Binding.Source range ->
      let s, e = range_bytes starts range in
      slice source s e
  | Grep.Binding.Ident ident -> ident

let build_site ~template ~template_ast ~holes source starts (location, bindings)
    =
  let range = Ocaml.Location.range location in
  let bs, be = range_bytes starts range in
  let before = slice source bs be in
  let site_texts =
    List.map
      (fun b -> (Grep.Binding.name b, site_text_of source starts b))
      bindings
  in
  match build_frags site_texts with
  | Error hole ->
      Error
        (Printf.sprintf "captured fragment for %s did not parse in isolation"
           hole)
  | Ok frags -> (
      let expected = expected_ast template_ast frags in
      let internal =
        match render template holes frags Minimal with
        | minimal when isolation_ok minimal expected -> Some minimal
        | _ ->
            let widened = render template holes frags Widened in
            if isolation_ok widened expected then Some widened else None
      in
      match internal with
      | None ->
          Error
            (Printf.sprintf
               "site at %d:%d cannot be parenthesized to the template's \
                structure"
               (Ocaml.Position.line (Ocaml.Range.start range))
               (Ocaml.Position.column (Ocaml.Range.start range)))
      | Some text ->
          Ok
            {
              st_start = bs;
              st_end = be;
              st_before = before;
              st_expected = expected;
              st_location = location;
              st_text = text;
              st_wrapped = false;
            })

(* Whole-file post-check with a per-site outer-paren retry: locate each site by
   exact range in the reparsed file and strip-compare to its expected AST. A
   mismatch or a missing node (boundary re-association) is outer capture; wrap
   that site whole and retry. A site that still fails after wrapping is an
   honest [Unrenderable] skip. Terminates: each site is wrapped at most once. *)
let rec verify_file ~path source sites =
  let after = apply_sites source sites in
  match
    Grep.parse_implementation ~filename:(Workspace.Path.display path) after
  with
  | Error message -> Error (`Rewrite_unparsable message)
  | Ok structure ->
      let spans = expr_spans structure in
      let failing =
        List.find_opt
          (fun (site, fstart, fend) ->
            match node_at spans fstart fend with
            | Some node -> Grep.strip_expr node <> site.st_expected
            | None -> true)
          (final_ranges sites)
      in
      begin match failing with
      | None -> Ok after
      | Some (site, _, _) ->
          if site.st_wrapped then
            Error
              (`Unrenderable
                 (Printf.sprintf
                    "site at %d.%d could not be reconciled with the template \
                     after parenthesization"
                    (Ocaml.Position.line
                       (Ocaml.Range.start
                          (Ocaml.Location.range site.st_location)))
                    (Ocaml.Position.column
                       (Ocaml.Range.start
                          (Ocaml.Location.range site.st_location)))))
          else begin
            site.st_text <- "(" ^ site.st_text ^ ")";
            site.st_wrapped <- true;
            verify_file ~path source sites
          end
      end

(* {1 Input} *)

module Input = struct
  type t = {
    pattern : string;
    template : string;
    paths : string list option;
    max_sites : int option;
    dry_run : bool;
  }

  let validate_path path =
    if String.is_empty path then
      invalid_arg "paths must not contain empty paths";
    if String.contains path '\000' then invalid_arg "paths must not contain NUL"

  let validate_paths = function
    | None -> ()
    | Some [] -> invalid_arg "paths must not be empty"
    | Some paths -> List.iter validate_path paths

  let validate_max_sites = function
    | None -> ()
    | Some n when n < 1 -> invalid_arg "max_sites must be at least 1"
    | Some n when n > max_max_sites ->
        invalid_arg ("max_sites must be at most " ^ string_of_int max_max_sites)
    | Some _ -> ()

  let make ?paths ?max_sites ?(dry_run = false) ~pattern ~template () =
    if String.is_empty pattern then invalid_arg "pattern must not be empty";
    if String.contains pattern '\000' then
      invalid_arg "pattern must not contain NUL";
    if String.is_empty template then invalid_arg "template must not be empty";
    if String.contains template '\000' then
      invalid_arg "template must not contain NUL";
    validate_paths paths;
    validate_max_sites max_sites;
    { pattern; template; paths; max_sites; dry_run }

  let pattern t = t.pattern
  let template t = t.template
  let paths t = t.paths
  let max_sites t = t.max_sites
  let dry_run t = t.dry_run

  let make_json pattern template paths max_sites dry_run =
    decode_invalid_arg (fun () ->
        make ?paths ?max_sites ?dry_run ~pattern ~template ())

  let codec =
    Jsont.Object.map ~kind:"ocaml_replace_expressions input" make_json
    |> Jsont.Object.mem "pattern" Jsont.string ~enc:pattern
    |> Jsont.Object.mem "template" Jsont.string ~enc:template
    |> Jsont.Object.opt_mem "paths" (Jsont.list Jsont.string) ~enc:paths
    |> Jsont.Object.opt_mem "max_sites" Jsont.int ~enc:max_sites
    |> Jsont.Object.opt_mem "dry_run" Jsont.bool ~enc:(fun t ->
        if t.dry_run then Some true else None)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "pattern",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "OCaml expression pattern. __ matches any expression, \
                         __1/__2 are unification metavariables reused by the \
                         template, and match/record clauses match as sets." );
                  ] );
              ( "template",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "OCaml expression with the same __1/__2 holes as the \
                         pattern. Each hole is filled with the exact source \
                         text the metavariable matched." );
                  ] );
              ( "paths",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", json_obj [ ("type", Json.string "string") ]);
                    ("minItems", Json.int 1);
                    ( "description",
                      Json.string
                        "Workspace-relative or workspace-contained file or \
                         directory roots. Defaults to the workspace current \
                         directory." );
                  ] );
              ( "max_sites",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_max_sites);
                    ( "description",
                      Json.string
                        "Maximum rewritten sites across all files. If \
                         exceeded, nothing is written. Defaults to 200." );
                  ] );
              ( "dry_run",
                json_obj
                  [
                    ("type", Json.string "boolean");
                    ( "description",
                      Json.string
                        "When true, validate and render but write nothing, \
                         returning per-site before/after and the diff. \
                         Defaults to false (the tool applies in one call)." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "pattern"; Json.string "template" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

(* {1 Output} *)

module Output = struct
  type skipped_reason =
    | Binary
    | Invalid_utf8
    | Too_large
    | Syntax_error of string
    | Read_error of string
    | Unrenderable of string
    | Rewrite_unparsable of string

  type skipped = { skipped_path : Workspace.Path.t; reason : skipped_reason }
  type site = { location : Ocaml.Location.t; before : string; after : string }
  type file = { file_path : Workspace.Path.t; sites : site list; diff : string }
  type status = Applied | Previewed

  type t = {
    pattern : string;
    template : string;
    roots : Workspace.Path.t list;
    status : status;
    files : file list;
    searched_files : int;
    skipped : skipped list;
    receipt : Receipt.t;
    final_identities : (Workspace.Path.t * Spice_digest.Identity.t) list;
  }

  let make ~pattern ~template ~roots ~status ~files ~searched_files ~skipped
      ~receipt ~final_identities =
    {
      pattern;
      template;
      roots;
      status;
      files;
      searched_files;
      skipped;
      receipt;
      final_identities;
    }

  let pattern t = t.pattern
  let template t = t.template
  let roots t = t.roots
  let status t = t.status
  let files t = t.files

  let total_sites t =
    List.fold_left (fun n f -> n + List.length f.sites) 0 t.files

  let searched_files t = t.searched_files
  let skipped t = t.skipped
  let receipt t = t.receipt
  let final_identities t = t.final_identities

  let status_to_string = function
    | Applied -> "applied"
    | Previewed -> "previewed"

  let skipped_reason_label = function
    | Binary -> "binary"
    | Invalid_utf8 -> "invalid_utf8"
    | Too_large -> "too_large"
    | Syntax_error _ -> "syntax_error"
    | Read_error _ -> "read_error"
    | Unrenderable _ -> "unrenderable"
    | Rewrite_unparsable _ -> "rewrite_unparsable"

  let skipped_reason_message = function
    | Binary | Invalid_utf8 | Too_large -> None
    | Syntax_error m | Read_error m | Unrenderable m | Rewrite_unparsable m ->
        Some m

  let one_line s =
    String.map
      (fun c -> if Char.equal c '\n' || Char.equal c '\r' then ' ' else c)
      s

  let site_json (s : site) =
    let range = Ocaml.Location.range s.location in
    let start = Ocaml.Range.start range in
    let end_ = Ocaml.Range.end_ range in
    json_obj
      [
        ( "path",
          Json.string (Workspace.Path.display (Ocaml.Location.path s.location))
        );
        ("start_line", Json.int (Ocaml.Position.line start));
        ("start_column", Json.int (Ocaml.Position.column start));
        ("end_line", Json.int (Ocaml.Position.line end_));
        ("end_column", Json.int (Ocaml.Position.column end_));
        ("before", Json.string s.before);
        ("after", Json.string s.after);
      ]

  let file_json (f : file) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display f.file_path));
        ("sites", Json.list (List.map site_json f.sites));
        ("diff", Json.string f.diff);
      ]

  let skipped_json (s : skipped) =
    json_obj
      [
        ("path", Json.string (Workspace.Path.display s.skipped_path));
        ("reason", Json.string (skipped_reason_label s.reason));
        ( "message",
          match skipped_reason_message s.reason with
          | None -> json_null
          | Some m -> Json.string m );
      ]

  let json t =
    json_obj
      [
        ("pattern", Json.string t.pattern);
        ("template", Json.string t.template);
        ( "roots",
          Json.list
            (List.map (fun p -> Json.string (Workspace.Path.display p)) t.roots)
        );
        ("status", Json.string (status_to_string t.status));
        ("total_sites", Json.int (total_sites t));
        ("searched_files", Json.int t.searched_files);
        ("files", Json.list (List.map file_json t.files));
        ("skipped", Json.list (List.map skipped_json t.skipped));
        ("skipped_count", Json.int (List.length t.skipped));
      ]

  let add_site b (s : site) =
    let range = Ocaml.Location.range s.location in
    let start = Ocaml.Range.start range in
    let end_ = Ocaml.Range.end_ range in
    Buffer.add_string b
      (Printf.sprintf "  %d.%d-%d.%d: %s -> %s\n"
         (Ocaml.Position.line start)
         (Ocaml.Position.column start)
         (Ocaml.Position.line end_)
         (Ocaml.Position.column end_)
         (one_line s.before) (one_line s.after))

  let add_file b (f : file) =
    Buffer.add_string b
      (Printf.sprintf "M %s (%d sites)\n"
         (Workspace.Path.display f.file_path)
         (List.length f.sites));
    List.iter (add_site b) f.sites

  let add_skipped b t =
    match t.skipped with
    | [] -> ()
    | skipped ->
        Buffer.add_string b "skipped:\n";
        List.iter
          (fun (s : skipped) ->
            Buffer.add_string b "  ";
            Buffer.add_string b (Workspace.Path.display s.skipped_path);
            Buffer.add_string b " reason=";
            Buffer.add_string b (skipped_reason_label s.reason);
            (match skipped_reason_message s.reason with
            | None -> ()
            | Some m ->
                Buffer.add_char b ' ';
                Buffer.add_string b m);
            Buffer.add_char b '\n')
          skipped

  let text t =
    let b = Buffer.create 512 in
    Buffer.add_string b
      (Printf.sprintf
         "ocaml_replace_expressions status=%s files=%d sites=%d searched=%d\n"
         (status_to_string t.status)
         (List.length t.files) (total_sites t) t.searched_files);
    (match t.files with
    | [] -> Buffer.add_string b "No rewrites\n"
    | files -> List.iter (add_file b) files);
    add_skipped b t;
    Buffer.contents b

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

(* {1 Discovery pipeline}

   Enumeration, size/binary/UTF-8 gating, and the base [skipped] taxonomy mirror
   {!Ocaml_search_expressions} exactly. That tool's pipeline is module-private,
   so the semantics are replicated here rather than shared; the constructors
   [Binary]/[Invalid_utf8]/[Too_large]/[Syntax_error]/[Read_error] are kept
   identical, and any change there must be mirrored here. *)

type search_error = Fs of Fs.Error.t | Enumerate of string | Cancelled

let default_cancelled () = false

let effective_paths input =
  match Input.paths input with None -> [ "." ] | Some paths -> paths

let effective_max_sites input =
  Option.value (Input.max_sites input) ~default:default_max_sites

let root_kind ~fs ~workspace path =
  match Fs.stat ~fs ~workspace ~follow_symlink:false path with
  | Error error -> Error (Fs error)
  | Ok None -> Error (Fs (Fs.Error.Not_found path))
  | Ok (Some stat) -> (
      match stat.Eio.File.Stat.kind with
      | `Regular_file -> (
          match Fs.regular ~fs ~workspace ~follow_symlink:false path with
          | Ok _ -> Ok `Regular_file
          | Error error -> Error (Fs error))
      | `Directory -> (
          match Fs.directory ~fs ~workspace ~follow_symlink:false path with
          | Ok _ -> Ok `Directory
          | Error error -> Error (Fs error))
      | kind ->
          Error
            (Fs
               (Fs.Error.Unexpected_kind
                  { path; expected = Fs.Regular_file; actual = kind })))

let resolve_roots ~fs ~workspace input =
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | raw :: raws -> (
        match Fs.resolve ~workspace raw with
        | Error error -> Error (Fs error)
        | Ok path -> (
            if Workspace.Path.Set.mem path seen then loop seen acc raws
            else
              match root_kind ~fs ~workspace path with
              | Error _ as error -> error
              | Ok kind ->
                  loop
                    (Workspace.Path.Set.add path seen)
                    ((path, kind) :: acc) raws))
  in
  loop Workspace.Path.Set.empty [] (effective_paths input)

let glob_page ~fs ~workspace ~cancelled input =
  let result = Glob.run ~fs ~workspace ~cancelled input in
  match Tool.Result.status result with
  | Tool.Result.Completed -> (
      match Tool.Result.output result with
      | Some output -> Ok (Glob.Output.files output, Glob.Output.next output)
      | None -> Error (Enumerate "file enumeration returned no output"))
  | Tool.Result.Failed { message; _ } -> Error (Enumerate message)
  | Tool.Result.Interrupted _ -> Error Cancelled

let enumerate_root ~fs ~workspace ~cancelled (path, kind) =
  match kind with
  | `Regular_file -> Ok [ path ]
  | `Directory ->
      let rec loop acc input =
        match glob_page ~fs ~workspace ~cancelled input with
        | Error _ as error -> error
        | Ok (files, next) -> (
            let acc = List.rev_append files acc in
            match next with
            | None -> Ok (List.rev acc)
            | Some next -> loop acc next)
      in
      loop []
        (Glob.Input.make
           ~path:(Workspace.Path.display path)
           ~limit:Glob.max_limit "**/*.ml")

let enumerate_candidates ~fs ~workspace ~cancelled roots =
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | root :: roots -> (
        match enumerate_root ~fs ~workspace ~cancelled root with
        | Error _ as error -> error
        | Ok files ->
            let seen, acc =
              List.fold_left
                (fun (seen, acc) file ->
                  if Workspace.Path.Set.mem file seen then (seen, acc)
                  else (Workspace.Path.Set.add file seen, file :: acc))
                (seen, acc) files
            in
            loop seen acc roots)
  in
  loop Workspace.Path.Set.empty [] roots

let read_source ~fs ~workspace path =
  match Fs.regular ~fs ~workspace ~follow_symlink:false path with
  | Error error -> Error (Output.Read_error (Fs.Error.message error))
  | Ok stat -> (
      let size = Optint.Int63.to_int64 stat.Eio.File.Stat.size in
      if Int64.compare size (Int64.of_int max_source_bytes) > 0 then
        Error Output.Too_large
      else
        match Fs.load_regular ~fs ~workspace ~follow_symlink:false path with
        | Error error -> Error (Output.Read_error (Fs.Error.message error))
        | Ok contents ->
            if Text_helpers.looks_binary contents then Error Output.Binary
            else if not (String.is_valid_utf_8 contents) then
              Error Output.Invalid_utf8
            else Ok contents)

let error_kind = function
  | Fs error -> Fs_error.failure error
  | Enumerate _ -> `Failed
  | Cancelled -> `Failed

let error_message = function
  | Fs (Fs.Error.Workspace error) -> Workspace.Resolve_error.message error
  | Fs (Fs.Error.Not_found path) ->
      Workspace.Path.display path ^ ": path does not exist"
  | Fs (Fs.Error.Escapes_workspace path) ->
      Workspace.Path.display path ^ ": path resolves outside workspace"
  | Fs (Fs.Error.Unexpected_kind { path; actual = `Symbolic_link; _ }) ->
      Workspace.Path.display path ^ ": symlink search roots are not supported"
  | Fs (Fs.Error.Unexpected_kind { path; _ }) ->
      Workspace.Path.display path ^ ": expected a regular file or directory"
  | Fs (Fs.Error.Io (None, _)) -> "filesystem I/O error"
  | Fs (Fs.Error.Io (Some path, _)) ->
      Workspace.Path.display path ^ ": filesystem I/O error"
  | Enumerate message -> "file enumeration failed: " ^ message
  | Cancelled -> "tool call cancelled"

let failed error = Tool.Result.failed (error_kind error) (error_message error)

let interrupted () =
  Tool.Result.interrupted ~reason:"tool call cancelled" ~cancelled:true ()

(* {1 Execution} *)

let permissions ~workspace input =
  let op = if Input.dry_run input then `Read else `Modify in
  let rec loop acc = function
    | [] -> List.rev acc
    | raw :: raws -> (
        match Workspace.resolve_string workspace raw with
        | Error _ -> loop acc raws
        | Ok path ->
            let request =
              Permission.Request.of_accesses ~source:name
                [ Permission.Access.path ~op path ]
            in
            loop (request :: acc) raws)
  in
  loop [] (effective_paths input)

let bounded excerpt =
  if String.length excerpt <= max_excerpt_bytes then excerpt
  else Text_helpers.valid_utf8_prefix excerpt max_excerpt_bytes

(* One matched file: its bytes and its per-site bindings. *)
type matched = {
  m_path : Workspace.Path.t;
  m_source : string;
  m_sites : (Ocaml.Location.t * Grep.Binding.t list) list;
}

let search_file ~fs ~workspace pattern path =
  match read_source ~fs ~workspace path with
  | Error reason -> `Skipped { Output.skipped_path = path; reason }
  | Ok source -> (
      let filename = Workspace.Path.display path in
      match Grep.parse_implementation ~filename source with
      | Error message ->
          `Skipped
            { Output.skipped_path = path; reason = Output.Syntax_error message }
      | Ok structure -> (
          match Grep.search_with_bindings pattern ~path structure with
          | [] -> `Searched
          | sites ->
              `Matched { m_path = path; m_source = source; m_sites = sites }))

(* Render and validate one matched file. Returns the per-file rewrite plan and
   output shape, or a per-file skip reason. *)
let render_matched ~template ~template_ast ~holes m =
  let path = m.m_path and source = m.m_source in
  let starts = line_starts source in
  let rec build acc = function
    | [] -> Ok (List.rev acc)
    | binding :: rest -> (
        match
          build_site ~template ~template_ast ~holes source starts binding
        with
        | Error message -> Error (Output.Unrenderable message)
        | Ok site -> build (site :: acc) rest)
  in
  match build [] m.m_sites with
  | Error reason -> Error reason
  | Ok sites -> (
      match verify_file ~path source sites with
      | Error (`Rewrite_unparsable message) ->
          Error (Output.Rewrite_unparsable message)
      | Error (`Unrenderable message) -> Error (Output.Unrenderable message)
      | Ok after -> (
          match Edit.rewrite ~path ~before:source ~after with
          | Error error ->
              Error (Output.Unrenderable (Edit.Error.message error))
          | Ok edit ->
              let diff = Edit.diff edit |> Spice_diff.to_string in
              let out_sites =
                List.map
                  (fun s ->
                    {
                      Output.location = s.st_location;
                      before = bounded s.st_before;
                      after = bounded s.st_text;
                    })
                  sites
              in
              Ok
                ( edit,
                  after,
                  { Output.file_path = path; sites = out_sites; diff } )))

let edit_io ~fs ~workspace ~max_bytes () =
  Fs.Edit.io ~fs ~workspace ~max_bytes ~create_parent_dirs:false
    ~allow_remove:false ()
  |> fst

let failed_edit = Edit_error.failed

let logical_change (file : Output.file) =
  {
    Receipt.Logical_change.path = file.Output.file_path;
    kind = Receipt.Logical_change.Modify;
    diff = Some file.Output.diff;
  }

let apply_files ~fs ~workspace ~max_bytes plans files afters =
  match Edit.concat plans with
  | Error error -> Error (failed_edit error)
  | Ok edit -> (
      if Edit.is_empty edit then Ok (Spice_edit.Result.empty, [])
      else
        let io = edit_io ~fs ~workspace ~max_bytes () in
        match Edit.apply ~io ~workspace edit with
        | Error apply_error ->
            Error (failed_edit (Edit.Apply_error.error apply_error))
        | Ok result ->
            let identities =
              List.map2
                (fun (file : Output.file) after ->
                  ( file.Output.file_path,
                    Spice_digest.Identity.of_contents after ))
                files afters
            in
            Ok (result, identities))

let default_max_bytes = 1024 * 1024

let run ~fs ~workspace ?(max_bytes = default_max_bytes)
    ?(cancelled = default_cancelled) input =
  if cancelled () then interrupted ()
  else
    match Grep.Pattern.parse (Input.pattern input) with
    | Error error ->
        Tool.Result.failed `Invalid_input (Grep.Pattern.error_message error)
    | Ok pattern -> (
        let pattern_metavars =
          match parse_expr (Input.pattern input) with
          | Some ast -> collect_metavars ast
          | None -> []
        in
        match validate_template ~pattern_metavars (Input.template input) with
        | Error message -> Tool.Result.failed `Invalid_input message
        | Ok (template, template_ast, holes) -> (
            match resolve_roots ~fs ~workspace input with
            | Error error -> failed error
            | Ok roots -> (
                let root_paths = List.map fst roots in
                match enumerate_candidates ~fs ~workspace ~cancelled roots with
                | Error Cancelled -> interrupted ()
                | Error ((Fs _ | Enumerate _) as error) -> failed error
                | Ok candidates ->
                    (* Search phase: match every file and count sites. *)
                    let rec search matched searched skips = function
                      | [] -> `Done (List.rev matched, searched, List.rev skips)
                      | path :: rest -> (
                          if cancelled () then `Cancelled
                          else
                            match search_file ~fs ~workspace pattern path with
                            | `Skipped skip ->
                                search matched searched (skip :: skips) rest
                            | `Searched ->
                                search matched (searched + 1) skips rest
                            | `Matched m ->
                                search (m :: matched) (searched + 1) skips rest)
                    in
                    begin match search [] 0 [] candidates with
                    | `Cancelled -> interrupted ()
                    | `Done (matched, searched, skips) -> (
                        (* Render and report in workspace-path order. *)
                        let matched =
                          List.sort
                            (fun a b ->
                              Workspace.Path.compare a.m_path b.m_path)
                            matched
                        in
                        let total =
                          List.fold_left
                            (fun n m -> n + List.length m.m_sites)
                            0 matched
                        in
                        let limit = effective_max_sites input in
                        if total > limit then
                          Tool.Result.failed `Failed
                            (Printf.sprintf
                               "found %d matching site(s), which exceeds \
                                max_sites=%d; narrow paths or raise max_sites \
                                (nothing was written)"
                               total limit)
                        else
                          (* Render phase. *)
                          let rec render files plans afters render_skips
                              render_fail = function
                            | [] ->
                                `Rendered
                                  ( List.rev files,
                                    List.rev plans,
                                    List.rev afters,
                                    List.rev render_skips,
                                    render_fail )
                            | m :: rest -> (
                                if cancelled () then `Cancelled
                                else
                                  match
                                    render_matched ~template ~template_ast
                                      ~holes m
                                  with
                                  | Error reason ->
                                      render files plans afters
                                        ({
                                           Output.skipped_path = m.m_path;
                                           reason;
                                         }
                                        :: render_skips)
                                        (render_fail + 1) rest
                                  | Ok (edit, after, file) ->
                                      render (file :: files) (edit :: plans)
                                        (after :: afters) render_skips
                                        render_fail rest)
                          in
                          match render [] [] [] [] 0 matched with
                          | `Cancelled -> interrupted ()
                          | `Rendered
                              (files, plans, afters, render_skips, render_fail)
                            -> (
                              let searched_files = searched - render_fail in
                              let skipped =
                                List.sort
                                  (fun (a : Output.skipped) (b : Output.skipped)
                                     ->
                                    Workspace.Path.compare a.Output.skipped_path
                                      b.Output.skipped_path)
                                  (skips @ render_skips)
                              in
                              let finish ~status ~receipt ~final_identities =
                                Tool.Result.completed
                                  ~output:
                                    (Output.make ~pattern:(Input.pattern input)
                                       ~template ~roots:root_paths ~status
                                       ~files ~searched_files ~skipped ~receipt
                                       ~final_identities)
                                  ()
                              in
                              if Input.dry_run input then
                                finish ~status:Output.Previewed
                                  ~receipt:Receipt.empty ~final_identities:[]
                              else if cancelled () then interrupted ()
                              else
                                match
                                  apply_files ~fs ~workspace ~max_bytes plans
                                    files afters
                                with
                                | Error failure -> failure
                                | Ok (result, final_identities) ->
                                    let receipt =
                                      Receipt.make
                                        ~logical_changes:
                                          (List.map logical_change files)
                                        result
                                    in
                                    finish ~status:Output.Applied ~receipt
                                      ~final_identities))
                    end)))

let tool ~fs ~workspace () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~workspace input)
    ~run:(fun ctx input ->
      run ~fs ~workspace ~cancelled:(fun () -> Tool.Context.cancelled ctx) input)
    ()
