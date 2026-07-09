(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC

  The pattern-matching semantics are derived from ocamlgrep,
  Copyright (C) 2000-2026 LexiFi, released under the MIT license.
 ---------------------------------------------------------------------------*)

open Asttypes
open Parsetree
open Ast_iterator
open Longident

(* Private control flow of a single match attempt. Never escapes this
   module: every entry point converts it to a boolean or a result. *)
exception Dont_match

let dont_match () = raise Dont_match

(* How to reproduce a bound metavariable's source at render time. An
   expression metavar carries the real range of its matched occurrence (bytes
   to slice); a pattern-variable or path-component metavar carries the bare
   identifier it bound, which has no interior formatting to preserve. *)
type capture = Cap_source of Location.t | Cap_ident of string

(* One bound metavariable: the stripped fragment used for unification and the
   capture used for rendering. *)
type bound = { fragment : Parsetree.expression; capture : capture }

(* Metavariable bindings of one match attempt, threaded explicitly. *)
type env = (string * bound) list ref

(* Metavariables are __ followed by one or more digits: __1, __23, ... *)
let is_metavar str =
  let len = String.length str in
  let rec digits i =
    i = len || match str.[i] with '0' .. '9' -> digits (i + 1) | _ -> false
  in
  len > 2 && str.[0] = '_' && str.[1] = '_' && digits 2

(* Structural comparison of bound fragments must ignore where and how the
   code was written, so bindings are stored location- and attribute-free. *)
let strip =
  let super = Ast_mapper.default_mapper in
  let expr self e =
    let e = super.Ast_mapper.expr self e in
    { e with pexp_loc_stack = [] }
  in
  let pat self p =
    let p = super.Ast_mapper.pat self p in
    { p with ppat_loc_stack = [] }
  in
  let typ self t =
    let t = super.Ast_mapper.typ self t in
    { t with ptyp_loc_stack = [] }
  in
  {
    super with
    Ast_mapper.location = (fun _ _ -> Location.none);
    Ast_mapper.attributes = (fun _ _ -> []);
    Ast_mapper.expr;
    Ast_mapper.pat;
    Ast_mapper.typ;
  }

let strip_expr expr = strip.Ast_mapper.expr strip expr
let structurally_equal_expr a b = strip_expr a = strip_expr b

let rec strip_lident lid =
  match lid with
  | Lident _ -> lid
  | Ldot (l, s) ->
      Ldot (Location.mknoloc (strip_lident l.txt), Location.mknoloc s.txt)
  | Lapply (l1, l2) ->
      Lapply
        ( Location.mknoloc (strip_lident l1.txt),
          Location.mknoloc (strip_lident l2.txt) )

let last_component lid =
  match lid with Lident s -> s | Ldot (_, s) -> s.txt | Lapply _ -> ""

let metavariables_in_expr root =
  let vars = ref [] in
  let add name =
    if is_metavar name && not (List.mem name !vars) then vars := name :: !vars
  in
  let rec lident = function
    | Lident name -> add name
    | Ldot (lid, name) ->
        lident lid.Location.txt;
        add name.Location.txt
    | Lapply (left, right) ->
        lident left.Location.txt;
        lident right.Location.txt
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
  let pat self pat =
    (match pat.ppat_desc with
    | Ppat_var { txt; _ } -> add txt
    | Ppat_construct ({ txt; _ }, _) -> lident txt
    | _ -> ());
    super.pat self pat
  in
  let iterator = { super with expr; pat } in
  iterator.expr iterator root;
  List.sort String.compare !vars

(* A capture is "real" only when it is an expression occurrence with a
   non-ghost location: its verbatim bytes beat a reconstructed identifier. *)
let real_capture = function
  | Cap_source loc -> not loc.Location.loc_ghost
  | Cap_ident _ -> false

(* Unification compares only the stripped [fragment]; the [capture] is render
   metadata. On a repeat occurrence the first-bound capture is kept, unless it
   is not yet a real source and the repeat is: an expression occurrence's real
   bytes are preferred over an earlier identifier or ghost range. This is the
   "first real source location" rule, applied without disturbing first-capture
   order. *)
let bind_metavar (env : env) id ~capture fragment =
  match List.assoc_opt id !env with
  | Some bound ->
      if fragment <> bound.fragment then dont_match ();
      if (not (real_capture bound.capture)) && real_capture capture then
        env :=
          List.map
            (fun (key, value) ->
              if String.equal key id then (key, { value with capture })
              else (key, value))
            !env
  | None -> env := (id, { fragment; capture }) :: !env

let bind_metavar_lident env id lid =
  bind_metavar env id
    ~capture:(Cap_ident (last_component lid))
    (Ast_helper.Exp.ident (Location.mknoloc (strip_lident lid)))

(* Order-independent matching: every target element must match some pattern
   element, and every pattern element must be used at least once. One
   pattern element may cover several target elements. *)
let match_set env f ps ts =
  let ps = List.mapi (fun i p -> (i, p)) ps in
  let all_used used = List.for_all (fun (i, _) -> List.mem i used) ps in
  let rec match_targets used = function
    | [] -> if not (all_used used) then dont_match ()
    | t :: ts ->
        let rec try_patterns = function
          | [] -> dont_match ()
          | (i, p) :: ps -> (
              let saved = !env in
              let used = if List.mem i used then used else i :: used in
              match
                f p t;
                match_targets used ts
              with
              | () -> ()
              | exception Dont_match ->
                  env := saved;
                  try_patterns ps)
        in
        try_patterns ps
  in
  match_targets [] ts

let match_opt f p t =
  match (p, t) with
  | None, None -> ()
  | None, Some _ | Some _, None -> dont_match ()
  | Some p, Some t -> f p t

let match_list f p t =
  if List.compare_lengths p t = 0 then List.iter2 f p t else dont_match ()

let match_labeled f (p_label, p) (t_label, t) =
  if not (Option.equal String.equal p_label t_label) then dont_match ();
  f p t

(* Identifier paths compare component-wise as written, with __ matching any
   component. A shorter path matches as a suffix of the longer one in either
   direction: pattern [filter] matches [List.filter], and pattern
   [List.filter] matches a bare [filter]. *)
let rec match_lident env p t =
  match (p, t) with
  | Lident "__", _ -> ()
  | Lident s, _ when is_metavar s -> bind_metavar_lident env s t
  | Lident s2, Lident s1 when s1 = s2 -> ()
  | Lident s2, Ldot (_, s1) when s1.txt = s2 -> ()
  | Ldot (_, s2), Lident s1 when s2.txt = s1 -> ()
  | Ldot (p0, s2), Ldot (t0, s1) when s1.txt = s2.txt || s2.txt = "__" ->
      match_lident env p0.txt t0.txt
  | (Lident _ | Ldot _ | Lapply _), (Lident _ | Ldot _ | Lapply _) ->
      dont_match ()

(* Literals compare by content; string delimiters and locations are
   ignored, literal spellings are not: 1_000 does not match 1000. *)
let constant_equal (p : Parsetree.constant) (t : Parsetree.constant) =
  match (p.pconst_desc, t.pconst_desc) with
  | Pconst_integer (a, sa), Pconst_integer (b, sb) -> a = b && sa = sb
  | Pconst_char a, Pconst_char b -> a = b
  | Pconst_string (a, _, _), Pconst_string (b, _, _) -> a = b
  | Pconst_float (a, sa), Pconst_float (b, sb) -> a = b && sa = sb
  | (Pconst_integer _ | Pconst_char _ | Pconst_string _ | Pconst_float _), _ ->
      false

let remove_first f l =
  let rec loop = function
    | [] -> []
    | x :: rest -> if f x then rest else x :: loop rest
  in
  loop l

(* Type annotations in the searched code are transparent: matching looks
   through (e : t) and (p : t) nodes on the target side. *)
let rec unwrap_expr texpr =
  match texpr.pexp_desc with
  | Pexp_constraint (e, _) | Pexp_coerce (e, _, _) -> unwrap_expr e
  | _ -> texpr

let rec unwrap_pat tpat =
  match tpat.ppat_desc with Ppat_constraint (p, _) -> unwrap_pat p | _ -> tpat

let rec match_expr env (pexpr : Parsetree.expression) texpr =
  let texpr = unwrap_expr texpr in
  if texpr.pexp_loc.Location.loc_ghost && not pexpr.pexp_loc.Location.loc_ghost
  then dont_match ();
  match (pexpr.pexp_desc, texpr.pexp_desc) with
  (* __ matches any expression *)
  | Pexp_ident { txt = Lident "__"; _ }, _ -> ()
  (* __N matches any expression and requires equality across occurrences *)
  | Pexp_ident { txt = Lident id; _ }, _ when is_metavar id ->
      bind_metavar env id ~capture:(Cap_source texpr.pexp_loc)
        (strip_expr texpr)
  | Pexp_ident { txt = plid; _ }, Pexp_ident { txt = tlid; _ } ->
      match_lident env plid tlid
  | Pexp_constant pconst, Pexp_constant tconst ->
      if not (constant_equal pconst tconst) then dont_match ()
  | Pexp_tuple pexprs, Pexp_tuple texprs ->
      match_list (match_labeled (match_expr env)) pexprs texprs
  | Pexp_array pexprs, Pexp_array texprs ->
      match_list (match_expr env) pexprs texprs
  | Pexp_apply (pf, pargs), Pexp_apply (tf, targs) ->
      match_expr env pf tf;
      match_arguments env pargs targs
  | Pexp_function (pparams, _, pbody), Pexp_function (tparams, _, tbody) ->
      match_list (match_param env) pparams tparams;
      match_function_body env pbody tbody
  | Pexp_construct (pcstr, parg), Pexp_construct (tcstr, targ) -> (
      match_lident env pcstr.txt tcstr.txt;
      match (parg, targ) with
      | Some { pexp_desc = Pexp_ident { txt = Lident "__"; _ }; _ }, _ -> ()
      | None, None -> ()
      | Some parg, Some targ -> match_expr env parg targ
      | None, Some _ | Some _, None -> dont_match ())
  | Pexp_variant (plabel, parg), Pexp_variant (tlabel, targ)
    when plabel = tlabel ->
      match_opt (match_expr env) parg targ
  | Pexp_match (pe, pcases), Pexp_match (te, tcases)
  | Pexp_try (pe, pcases), Pexp_try (te, tcases) ->
      match_expr env pe te;
      match_cases env pcases tcases
  | Pexp_let (prf, pvbs, pe), Pexp_let (trf, tvbs, te) when prf = trf ->
      match_expr env pe te;
      match_set env (match_value_binding env) pvbs tvbs
  | Pexp_ifthenelse (pe1, pe2, pe3), Pexp_ifthenelse (te1, te2, te3) ->
      match_expr env pe1 te1;
      match_expr env pe2 te2;
      match_opt (match_expr env) pe3 te3
  | Pexp_sequence (pe1, pe2), Pexp_sequence (te1, te2)
  | Pexp_while (pe1, pe2), Pexp_while (te1, te2) ->
      match_expr env pe1 te1;
      match_expr env pe2 te2
  | Pexp_assert pe, Pexp_assert te | Pexp_lazy pe, Pexp_lazy te ->
      match_expr env pe te
  | Pexp_field (pe, plid), Pexp_field (te, tlid) ->
      match_lident env plid.txt tlid.txt;
      match_expr env pe te
  | Pexp_setfield (pe1, plid, pe2), Pexp_setfield (te1, tlid, te2) ->
      match_lident env plid.txt tlid.txt;
      match_expr env pe1 te1;
      match_expr env pe2 te2
  (* e.lid also matches the assignment e.lid <- v *)
  | Pexp_field (pe, plid), Pexp_setfield (te1, tlid, _) ->
      match_lident env plid.txt tlid.txt;
      match_expr env pe te1
  | Pexp_record (pfields, pbase), Pexp_record (tfields, tbase) ->
      match_opt (match_expr env) pbase tbase;
      let match_field (plid, pe) (tlid, te) =
        match_lident env plid.Location.txt tlid.Location.txt;
        match_expr env pe te
      in
      match_set env match_field pfields tfields
  | Pexp_send (pe, pmeth), Pexp_send (te, tmeth)
    when pmeth.Location.txt = tmeth.Location.txt ->
      match_expr env pe te
  | Pexp_new plid, Pexp_new tlid -> match_lident env plid.txt tlid.txt
  | ( Pexp_for (ppat, pe1, pe2, pdir, pbody),
      Pexp_for (tpat, te1, te2, tdir, tbody) )
    when pdir = tdir ->
      (match (ppat.ppat_desc, tpat.ppat_desc) with
      | Ppat_any, Ppat_any -> ()
      | Ppat_var { txt = "__"; _ }, (Ppat_any | Ppat_var _) -> ()
      | Ppat_var { txt = ps; _ }, Ppat_var { txt = ts; _ } when ps = ts -> ()
      | _, _ -> dont_match ());
      match_expr env pe1 te1;
      match_expr env pe2 te2;
      match_expr env pbody tbody
  | ( ( Pexp_ident _ | Pexp_constant _ | Pexp_let _ | Pexp_function _
      | Pexp_apply _ | Pexp_match _ | Pexp_try _ | Pexp_tuple _
      | Pexp_construct _ | Pexp_variant _ | Pexp_record _ | Pexp_field _
      | Pexp_setfield _ | Pexp_array _ | Pexp_ifthenelse _ | Pexp_sequence _
      | Pexp_while _ | Pexp_for _ | Pexp_constraint _ | Pexp_coerce _
      | Pexp_send _ | Pexp_new _ | Pexp_setinstvar _ | Pexp_override _
      | Pexp_struct_item _ | Pexp_assert _ | Pexp_lazy _ | Pexp_poly _
      | Pexp_object _ | Pexp_newtype _ | Pexp_pack _ | Pexp_letop _
      | Pexp_extension _ | Pexp_unreachable ),
      _ ) ->
      dont_match ()

(* Pattern arguments may omit any arguments of the call. Each pattern
   argument consumes the first remaining target argument with the same
   label; leftover target arguments are ignored. *)
and match_arguments env pargs targs =
  let rec check_all targs = function
    | [] -> ()
    | ( (Asttypes.Optional _ as label),
        {
          pexp_desc =
            Pexp_construct
              ({ txt = Lident (("MISSING" | "PRESENT") as form); _ }, None);
          _;
        } )
      :: pargs ->
        let required_present = form = "PRESENT" in
        let present = List.exists (fun (l, _) -> l = label) targs in
        if present <> required_present then dont_match ();
        let targs =
          if present then remove_first (fun (l, _) -> l = label) targs
          else targs
        in
        check_all targs pargs
    | (label, parg) :: pargs ->
        let rec consume = function
          | [] -> dont_match ()
          | (l, targ) :: targs when l = label ->
              match_expr env parg targ;
              targs
          | targ :: targs -> targ :: consume targs
        in
        check_all (consume targs) pargs
  in
  check_all targs pargs

and match_param env (p : Parsetree.function_param)
    (t : Parsetree.function_param) =
  match (p.pparam_desc, t.pparam_desc) with
  | Pparam_val (plabel, pdefault, ppat), Pparam_val (tlabel, tdefault, tpat) ->
      if plabel <> tlabel then dont_match ();
      match_opt (match_expr env) pdefault tdefault;
      match_pat env ppat tpat
  | Pparam_newtype pname, Pparam_newtype tname ->
      if not (pname.txt = tname.txt || pname.txt = "__") then dont_match ()
  | (Pparam_val _ | Pparam_newtype _), _ -> dont_match ()

and match_function_body env pbody tbody =
  match (pbody, tbody) with
  | Pfunction_body pe, Pfunction_body te -> match_expr env pe te
  | Pfunction_cases (pcases, _, _), Pfunction_cases (tcases, _, _) ->
      match_cases env pcases tcases
  | (Pfunction_body _ | Pfunction_cases _), _ -> dont_match ()

and match_cases env pcases tcases = match_set env (match_case env) pcases tcases

and match_case env pcase tcase =
  match_pat env pcase.pc_lhs tcase.pc_lhs;
  match_opt (match_expr env) pcase.pc_guard tcase.pc_guard;
  match_expr env pcase.pc_rhs tcase.pc_rhs

and match_value_binding env pvb tvb =
  match_expr env pvb.pvb_expr tvb.pvb_expr;
  match_pat env pvb.pvb_pat tvb.pvb_pat

and match_pat env (ppat : Parsetree.pattern) tpat =
  let tpat = unwrap_pat tpat in
  match (ppat.ppat_desc, tpat.ppat_desc) with
  | Ppat_any, Ppat_any -> ()
  (* __ matches any pattern *)
  | Ppat_var { txt = "__"; _ }, _ -> ()
  | Ppat_var { txt = ps; _ }, Ppat_var { txt = ts; _ } when is_metavar ps ->
      bind_metavar_lident env ps (Lident ts)
  | Ppat_var { txt = ps; _ }, Ppat_var { txt = ts; _ } when ps = ts -> ()
  | Ppat_tuple (ppats, _), Ppat_tuple (tpats, _) ->
      match_list (match_labeled (match_pat env)) ppats tpats
  | Ppat_constant pconst, Ppat_constant tconst ->
      if not (constant_equal pconst tconst) then dont_match ()
  | Ppat_construct (pcstr, parg), Ppat_construct (tcstr, targ) -> (
      match_lident env pcstr.txt tcstr.txt;
      match (parg, targ) with
      | None, None -> ()
      | Some (_, parg), Some (_, targ) -> match_pat env parg targ
      | None, Some _ | Some _, None -> dont_match ())
  | Ppat_variant (plabel, parg), Ppat_variant (tlabel, targ)
    when plabel = tlabel ->
      match_opt (match_pat env) parg targ
  | Ppat_record (pfields, _), Ppat_record (tfields, _) ->
      let match_field (plid, pp) (tlid, tp) =
        match_lident env plid.Location.txt tlid.Location.txt;
        match_pat env pp tp
      in
      match_set env match_field pfields tfields
  | Ppat_array ppats, Ppat_array tpats -> match_list (match_pat env) ppats tpats
  | Ppat_or (pp1, pp2), Ppat_or (tp1, tp2) ->
      match_pat env pp1 tp1;
      match_pat env pp2 tp2
  | Ppat_lazy pp, Ppat_lazy tp -> match_pat env pp tp
  | ( ( Ppat_any | Ppat_var _ | Ppat_alias _ | Ppat_constant _ | Ppat_interval _
      | Ppat_tuple _ | Ppat_construct _ | Ppat_variant _ | Ppat_record _
      | Ppat_array _ | Ppat_or _ | Ppat_constraint _ | Ppat_type _ | Ppat_lazy _
      | Ppat_unpack _ | Ppat_exception _ | Ppat_effect _ | Ppat_extension _
      | Ppat_open _ ),
      _ ) ->
      dont_match ()

(* The pattern __.id matches any pattern { ...; P.id; ... }, so that
   searching for a record field also finds reads in patterns. *)
let match_pat_expr (pexpr : Parsetree.expression) tpat =
  match (pexpr.pexp_desc, tpat.ppat_desc) with
  | ( Pexp_field
        ( { pexp_desc = Pexp_ident { txt = Lident "__"; _ }; _ },
          { txt = Lident field; _ } ),
      Ppat_record (tfields, _) ) ->
      if
        not
          (List.exists
             (fun (tlid, _) -> last_component tlid.Location.txt = field)
             tfields)
      then dont_match ()
  | _, _ -> dont_match ()

(* {1 Patterns} *)

module Pattern = struct
  type t = { source : string; parsed : Parsetree.expression }
  type error = Syntax of string | Unsupported of string

  let error_message = function Syntax m -> m | Unsupported m -> m
  let source t = t.source
  let is_metavariable_name = is_metavar
  let metavariables t = metavariables_in_expr t.parsed

  exception Unsupported_found of string

  (* Type constraints require a typed backend; reject them up front so the
     syntax stays reserved for it. *)
  let validate expr =
    let super = Ast_iterator.default_iterator in
    let reject what =
      raise
        (Unsupported_found
           (what
          ^ " is not supported: type-constrained patterns require a typed \
             backend"))
    in
    let expr_iter self e =
      match e.pexp_desc with
      | Pexp_constraint _ -> reject "type-constrained expression (e : t)"
      | Pexp_coerce _ -> reject "coercion (e :> t)"
      | _ -> super.expr self e
    in
    let pat_iter self p =
      match p.ppat_desc with
      | Ppat_constraint _ -> reject "type-constrained pattern (p : t)"
      | _ -> super.pat self p
    in
    let value_binding_iter self vb =
      match vb.pvb_constraint with
      | Some _ -> reject "type-annotated binding (let x : t = ...)"
      | None -> super.value_binding self vb
    in
    let iter =
      {
        super with
        expr = expr_iter;
        pat = pat_iter;
        value_binding = value_binding_iter;
      }
    in
    match iter.expr iter expr with
    | () -> Ok ()
    | exception Unsupported_found message -> Error message

  let parse query =
    match Parse.expression (Lexing.from_string query) with
    | exception _ -> Error (Syntax "the query is not a valid OCaml expression")
    | parsed -> (
        match validate parsed with
        | Ok () -> Ok { source = query; parsed }
        | Error message -> Error (Unsupported message))
end

(* {1 Parsing searched sources} *)

module Parse_error = struct
  type t = {
    filename : string;
    message : string;
    position : Spice_ocaml.Position.t option;
  }

  let make ~filename ~message ?position () =
    if String.equal filename "" then invalid_arg "parse error filename is empty";
    if String.equal message "" then invalid_arg "parse error message is empty";
    { filename; message; position }

  let filename t = t.filename
  let message t = t.message
  let position t = t.position

  let to_string t =
    match t.position with
    | None -> t.message
    | Some position ->
        Printf.sprintf "%s at line %d, column %d" t.message
          (Spice_ocaml.Position.line position)
          (Spice_ocaml.Position.column position)

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

let parse_implementation ~filename source =
  let lexbuf = Lexing.from_string source in
  lexbuf.Lexing.lex_curr_p <-
    {
      Lexing.pos_fname = filename;
      Lexing.pos_lnum = 1;
      Lexing.pos_bol = 0;
      Lexing.pos_cnum = 0;
    };
  match Parse.implementation lexbuf with
  | structure -> Ok structure
  | exception exn ->
      let position =
        match exn with
        | Syntaxerr.Error error ->
            let loc = Syntaxerr.location_of_error error in
            let start = loc.Location.loc_start in
            Some
              (Spice_ocaml.Position.make ~line:start.Lexing.pos_lnum
                 ~column:(start.Lexing.pos_cnum - start.Lexing.pos_bol))
        | _ -> None
      in
      Error (Parse_error.make ~filename ~message:"syntax error" ?position ())

(* {1 Search} *)

let range_of_compiler_loc (loc : Location.t) =
  let position (p : Lexing.position) =
    Spice_ocaml.Position.make ~line:p.Lexing.pos_lnum
      ~column:(p.Lexing.pos_cnum - p.Lexing.pos_bol)
  in
  Spice_ocaml.Range.make
    ~start:(position loc.Location.loc_start)
    ~end_:(position loc.Location.loc_end)

let location_of_compiler_loc ~path (loc : Location.t) =
  Spice_ocaml.Location.make ~path ~range:(range_of_compiler_loc loc)

let search (pattern : Pattern.t) ~path structure =
  let query = pattern.Pattern.parsed in
  let matches = ref [] in
  let super = Ast_iterator.default_iterator in
  let expr_iter self e =
    let env : env = ref [] in
    match match_expr env query e with
    | () ->
        if not e.pexp_loc.Location.loc_ghost then
          matches := e.pexp_loc :: !matches
    | exception Dont_match -> super.expr self e
  in
  let pat_iter self p =
    match match_pat_expr query p with
    | () ->
        if not p.ppat_loc.Location.loc_ghost then
          matches := p.ppat_loc :: !matches
    | exception Dont_match -> super.pat self p
  in
  let iter = { super with expr = expr_iter; pat = pat_iter } in
  iter.structure iter structure;
  List.map (location_of_compiler_loc ~path) !matches
  |> List.sort_uniq Spice_ocaml.Location.compare

(* {1 Metavariable bindings} *)

module Binding = struct
  type captured = Source of Spice_ocaml.Range.t | Ident of string
  type t = { name : string; captured : captured }

  let name t = t.name
  let captured t = t.captured
end

let binding_of_bound (name, bound) =
  let captured =
    match bound.capture with
    | Cap_source loc -> Binding.Source (range_of_compiler_loc loc)
    | Cap_ident ident -> Binding.Ident ident
  in
  { Binding.name; captured }

let search_with_bindings (pattern : Pattern.t) ~path structure =
  let query = pattern.Pattern.parsed in
  let matches = ref [] in
  let super = Ast_iterator.default_iterator in
  let expr_iter self e =
    let env : env = ref [] in
    match match_expr env query e with
    | () ->
        if not e.pexp_loc.Location.loc_ghost then
          matches := (e.pexp_loc, !env) :: !matches
    | exception Dont_match -> super.expr self e
  in
  (* Only expression matches carry bindings; [__.id]-in-pattern matches bind no
     metavariables and are not rewrite targets, so [pat] is left at its default
     descent. *)
  let iter = { super with expr = expr_iter } in
  iter.structure iter structure;
  let convert (loc, env) =
    (* [env] is most-recent-first; [rev_map] yields first-capture order. *)
    (location_of_compiler_loc ~path loc, List.rev_map binding_of_bound env)
  in
  let sorted =
    List.map convert !matches
    |> List.sort (fun (a, _) (b, _) -> Spice_ocaml.Location.compare a b)
  in
  let rec dedup acc = function
    | [] -> List.rev acc
    | ((loc, _) as entry) :: rest -> (
        match acc with
        | (prev, _) :: _ when Spice_ocaml.Location.compare prev loc = 0 ->
            dedup acc rest
        | _ -> dedup (entry :: acc) rest)
  in
  dedup [] sorted
