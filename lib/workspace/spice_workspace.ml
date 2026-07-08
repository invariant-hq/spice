(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Error = Error
module Resolve_error = Resolve_error
module Root = Root
module Path = Path

type t = { roots : Root.t list; cwd : Path.t }

let error error = Error error
let find_root workspace root = List.find_opt (Root.equal root) workspace.roots
let contains_root workspace root = List.exists (Root.equal root) workspace.roots

let unique_roots roots =
  let same_dir a b = Spice_path.Abs.equal (Root.dir a) (Root.dir b) in
  let find_conflict root roots =
    List.find_opt
      (fun existing -> Root.same_key existing root || same_dir existing root)
      (List.rev roots)
  in
  let rec loop seen acc = function
    | [] -> Ok (List.rev acc)
    | root :: roots -> (
        match find_conflict root seen with
        | Some existing ->
            if Root.equal existing root then loop seen acc roots
            else error (Error.Conflicting_root { existing; duplicate = root })
        | None -> loop (root :: seen) (root :: acc) roots)
  in
  loop [] [] roots

let canonical_path workspace path =
  Option.map
    (fun root -> Path.make ~root (Path.rel path))
    (find_root workspace (Path.root path))

let make ?cwd roots =
  match unique_roots roots with
  | Error _ as error -> error
  | Ok roots -> (
      match roots with
      | [] -> error Error.Empty_roots
      | first :: _ as roots -> (
          let cwd =
            match cwd with
            | Some cwd -> cwd
            | None -> Path.make ~root:first Spice_path.Rel.root
          in
          let workspace = { roots; cwd } in
          match canonical_path workspace cwd with
          | Some cwd -> Ok { workspace with cwd }
          | None -> error (Error.Root_not_in_workspace (Path.root cwd))))

let single ?(cwd = Spice_path.Rel.root) root =
  { roots = [ root ]; cwd = Path.make ~root cwd }

let roots t = t.roots
let cwd t = t.cwd

let root_path t =
  match t.roots with
  | root :: _ -> Path.make ~root Spice_path.Rel.root
  | [] -> invalid_arg "workspace has no roots"

let cwd_root_path t = Path.make ~root:(Path.root t.cwd) Spice_path.Rel.root
let path_at_cwd_root t rel = Path.make ~root:(Path.root t.cwd) rel

let with_cwd t cwd =
  match canonical_path t cwd with
  | Some cwd -> Ok { t with cwd }
  | None -> error (Error.Root_not_in_workspace (Path.root cwd))

let make_path t ~root rel =
  match find_root t root with
  | Some root -> Ok (Path.make ~root rel)
  | None -> error (Error.Root_not_in_workspace root)

let contains_path t path = contains_root t (Path.root path)
let specificity root = List.length (Spice_path.Abs.components (Root.dir root))

let import_path t abs =
  let better root rel specificity current =
    match current with
    | None -> Some (root, rel, specificity)
    | Some (_, _, current_specificity) ->
        if specificity > current_specificity then Some (root, rel, specificity)
        else current
  in
  let rec loop best = function
    | [] -> best
    | root :: roots ->
        let best =
          match Spice_path.Abs.relativize ~root:(Root.dir root) abs with
          | None -> best
          | Some rel -> better root rel (specificity root) best
        in
        loop best roots
  in
  Option.map (fun (root, rel, _) -> (root, rel)) (loop None t.roots)

let import_abs t abs =
  match import_path t abs with
  | None -> error (Resolve_error.Outside_workspace abs)
  | Some (root, rel) -> Ok (Path.make ~root rel)

let resolve_string t input =
  if (not (String.is_empty input)) && Char.equal input.[0] '/' then
    match Spice_path.Abs.of_string input with
    | Error path_error -> error (Resolve_error.Invalid_input path_error)
    | Ok abs -> import_abs t abs
  else
    match Spice_path.Abs.resolve (Path.abs t.cwd) input with
    | Error path_error -> error (Resolve_error.Invalid_input path_error)
    | Ok abs -> import_abs t abs

let equal a b = List.equal Root.equal a.roots b.roots && Path.equal a.cwd b.cwd

let pp_roots ppf roots =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
    Root.pp ppf roots

let pp ppf t =
  Format.fprintf ppf "@[<2>{ roots = [%a];@ cwd = %a }@]" pp_roots t.roots
    Path.pp t.cwd
