(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = {
  feature : Feature.t;
  crs : Spice_cr.Occurrence.t array;
  marks : Mark.t list; (* sorted by scope, one mark per scope *)
  verdict : Verdict.t;
  cursor : Cursor.t;
}

(* Evidence identities. Hunk evidence covers changed lines only, tagged by
   kind and newline presence, so it is independent of position and context.
   Line evidence covers one line's side, text, and newline presence. *)

let hunk_evidence hunk =
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer "hunk";
  List.iter
    (fun line ->
      match Spice_diff.Hunk.Line.kind line with
      | Spice_diff.Hunk.Line.Context -> ()
      | Spice_diff.Hunk.Line.Added | Spice_diff.Hunk.Line.Removed ->
          Buffer.add_char buffer '\x00';
          Buffer.add_char buffer
            (match Spice_diff.Hunk.Line.kind line with
            | Spice_diff.Hunk.Line.Added -> '+'
            | _ -> '-');
          Buffer.add_char buffer
            (if Spice_diff.Hunk.Line.newline line then 'n' else 'x');
          Feature.add_frame buffer (Spice_diff.Hunk.Line.text line))
    (Spice_diff.Hunk.lines hunk);
  Spice_digest.Identity.of_contents (Buffer.contents buffer)

let line_evidence ~side line =
  let buffer = Buffer.create 64 in
  Buffer.add_string buffer "line";
  Buffer.add_char buffer (match side with Scope.Old -> 'o' | Scope.New -> 'n');
  Buffer.add_char buffer
    (if Spice_diff.Hunk.Line.newline line then 'n' else 'x');
  Feature.add_frame buffer (Spice_diff.Hunk.Line.text line);
  Spice_digest.Identity.of_contents (Buffer.contents buffer)

let find_line hunks ~side ~line =
  List.find_map
    (fun hunk ->
      List.find_opt
        (fun candidate ->
          let number =
            match side with
            | Scope.Old -> Spice_diff.Hunk.Line.old_line candidate
            | Scope.New -> Spice_diff.Hunk.Line.new_line candidate
          in
          match number with Some n -> Int.equal n line | None -> false)
        (Spice_diff.Hunk.lines hunk))
    hunks

let hunk_matches_scope (h : Scope.t) hunk =
  match h with
  | Scope.Hunk { old_start; old_count; new_start; new_count; _ } ->
      Int.equal (Spice_diff.Hunk.old_start hunk) old_start
      && Int.equal (Spice_diff.Hunk.old_count hunk) old_count
      && Int.equal (Spice_diff.Hunk.new_start hunk) new_start
      && Int.equal (Spice_diff.Hunk.new_count hunk) new_count
  | _ -> false

let invalid_scope message = Error (Error.make Error.Invalid_scope message)

let scope_evidence t scope =
  match scope with
  | Scope.Feature -> Ok (Feature.digest t.feature)
  | Scope.File path -> (
      match Feature.find_file t.feature ~path with
      | Some file -> Ok (Feature.File.digest file)
      | None -> invalid_scope "no such file in the feature")
  | Scope.Hunk { path; _ } -> (
      match Feature.find_file t.feature ~path with
      | None -> invalid_scope "no such file in the feature"
      | Some file -> (
          match Feature.File.content file with
          | Feature.File.Opaque _ -> invalid_scope "file has no hunks"
          | Feature.File.Text hunks -> (
              match List.find_opt (hunk_matches_scope scope) hunks with
              | Some hunk -> Ok (hunk_evidence hunk)
              | None -> invalid_scope "no such hunk in the file")))
  | Scope.Line (side, path, line) -> (
      match Feature.find_file t.feature ~path with
      | None -> invalid_scope "no such file in the feature"
      | Some file -> (
          match Feature.File.content file with
          | Feature.File.Opaque _ -> invalid_scope "file has no lines"
          | Feature.File.Text hunks -> (
              match find_line hunks ~side ~line with
              | Some found -> Ok (line_evidence ~side found)
              | None -> invalid_scope "no such line in the file's hunks")))

(* Marks *)

let insert_mark marks mark =
  let scope = Mark.scope mark in
  let rec insert = function
    | [] -> [ mark ]
    | existing :: rest ->
        let c = Scope.compare (Mark.scope existing) scope in
        if c < 0 then existing :: insert rest
        else if c = 0 then mark :: rest
        else mark :: existing :: rest
  in
  insert marks

let set_mark state t scope =
  match scope_evidence t scope with
  | Error _ as error -> error
  | Ok evidence ->
      let marks =
        List.filter
          (fun mark -> not (Scope.contains scope (Mark.scope mark)))
          t.marks
      in
      let mark = Mark.make ~scope ~state ~evidence in
      Ok { t with marks = insert_mark marks mark }

let mark_reviewed t scope = set_mark Mark.Reviewed t scope
let mark_unreviewed t scope = set_mark Mark.Unreviewed t scope

let clear_mark t scope =
  {
    t with
    marks =
      List.filter
        (fun mark -> not (Scope.equal (Mark.scope mark) scope))
        t.marks;
  }

let marks t = t.marks

let mark t scope =
  List.find_opt (fun mark -> Scope.equal (Mark.scope mark) scope) t.marks

let effective_mark t scope =
  List.fold_left
    (fun best candidate ->
      if Scope.contains (Mark.scope candidate) scope then
        match best with
        | None -> Some candidate
        | Some current ->
            if
              Scope.rank (Mark.scope candidate)
              > Scope.rank (Mark.scope current)
            then Some candidate
            else best
      else best)
    None t.marks

let is_reviewed t scope =
  match effective_mark t scope with
  | Some mark -> (
      match Mark.state mark with Mark.Reviewed -> true | _ -> false)
  | None -> false

(* Occurrences *)

let crs t = Array.to_list t.crs

let cr t index =
  if index >= 0 && index < Array.length t.crs then Some t.crs.(index) else None

(* Navigation. The canonical review order is the feature scope, then per
   file in path order the file scope, its hunks, and its CR occurrences,
   then occurrences outside the feature's files in path order. *)

let stops t =
  let files = Feature.files t.feature in
  let indexed =
    Array.to_list (Array.mapi (fun index occ -> (index, occ)) t.crs)
  in
  let in_file path (_, occ) =
    Spice_path.Rel.equal (Spice_cr.Occurrence.path occ) path
  in
  let file_stops file =
    let path = Feature.File.path file in
    let hunk_stops =
      match Feature.File.content file with
      | Feature.File.Text hunks ->
          List.map (fun hunk -> Cursor.Scope (Scope.of_hunk ~path hunk)) hunks
      | Feature.File.Opaque _ -> []
    in
    (Cursor.Scope (Scope.File path) :: hunk_stops)
    @ List.filter_map
        (fun entry ->
          if in_file path entry then Some (Cursor.Cr (fst entry)) else None)
        indexed
  in
  let feature_paths = List.map Feature.File.path files in
  let outside =
    List.filter
      (fun (_, occ) ->
        let rel = Spice_cr.Occurrence.path occ in
        not (List.exists (Spice_path.Rel.equal rel) feature_paths))
      indexed
  in
  let outside =
    List.sort
      (fun (i, a) (j, b) ->
        let c =
          Spice_path.Rel.compare
            (Spice_cr.Occurrence.path a)
            (Spice_cr.Occurrence.path b)
        in
        if c <> 0 then c else Int.compare i j)
      outside
  in
  (Cursor.Scope Scope.Feature :: List.concat_map file_stops files)
  @ List.map (fun (index, _) -> Cursor.Cr index) outside

let position t stop_array =
  let target = t.cursor in
  let find predicate =
    let n = Array.length stop_array in
    let rec loop i =
      if i >= n then None
      else if predicate stop_array.(i) then Some i
      else loop (i + 1)
    in
    loop 0
  in
  match find (fun stop -> Cursor.equal stop target) with
  | Some index -> index
  | None -> (
      let containing rank_check scope =
        find (fun stop ->
            match stop with
            | Cursor.Scope candidate ->
                Scope.contains candidate scope && rank_check candidate
            | Cursor.Cr _ -> false)
      in
      match target with
      | Cursor.Scope scope -> (
          let is_hunk = function Scope.Hunk _ -> true | _ -> false in
          let is_file = function Scope.File _ -> true | _ -> false in
          match containing is_hunk scope with
          | Some index -> index
          | None -> (
              match containing is_file scope with
              | Some index -> index
              | None -> 0))
      | Cursor.Cr _ -> 0)

let move_cursor ?(wrap = false) t move =
  let stop_array = Array.of_list (stops t) in
  let n = Array.length stop_array in
  if n = 0 then t
  else
    let index = position t stop_array in
    let clamp i =
      if wrap then ((i mod n) + n) mod n else max 0 (min (n - 1) i)
    in
    let is_file = function
      | Cursor.Scope (Scope.File _) -> true
      | Cursor.Scope _ | Cursor.Cr _ -> false
    in
    let is_cr = function Cursor.Cr _ -> true | Cursor.Scope _ -> false in
    let find_from step predicate start =
      let rec loop i remaining =
        if remaining = 0 then None
        else
          let i = if wrap then ((i mod n) + n) mod n else i in
          if i < 0 || i >= n then None
          else if predicate stop_array.(i) then Some i
          else loop (i + step) (remaining - 1)
      in
      loop start n
    in
    let destination =
      match move with
      | Cursor.Next -> Some (clamp (index + 1))
      | Cursor.Previous -> Some (clamp (index - 1))
      | Cursor.First -> Some 0
      | Cursor.Last -> Some (n - 1)
      | Cursor.Next_file -> find_from 1 is_file (index + 1)
      | Cursor.Previous_file -> find_from (-1) is_file (index - 1)
      | Cursor.Next_cr -> find_from 1 is_cr (index + 1)
      | Cursor.Previous_cr -> find_from (-1) is_cr (index - 1)
    in
    match destination with
    | None -> t
    | Some i -> { t with cursor = stop_array.(i) }

let set_cursor t cursor =
  let valid =
    match cursor with
    | Cursor.Cr index -> index >= 0 && index < Array.length t.crs
    | Cursor.Scope scope -> Result.is_ok (scope_evidence t scope)
  in
  if valid then Ok { t with cursor }
  else Error (Error.make Error.Invalid_cursor "cursor target does not exist")

(* Verdict *)

let verdict t = t.verdict

let verdict_freshness t =
  Verdict.freshness t.verdict ~feature:(Feature.digest t.feature)

let approve t =
  { t with verdict = Verdict.Approved { feature = Feature.digest t.feature } }

let set_pending t = { t with verdict = Verdict.Pending }

(* Construction and refresh *)

let v ~feature ~crs =
  {
    feature;
    crs = Array.of_list crs;
    marks = [];
    verdict = Verdict.Pending;
    cursor = Cursor.feature;
  }

let carry_mark feature mark =
  let evidence = Mark.evidence mark in
  let state = Mark.state mark in
  match Mark.scope mark with
  | Scope.Feature ->
      if Spice_digest.Identity.equal (Feature.digest feature) evidence then
        Some mark
      else None
  | Scope.File path -> (
      match Feature.find_file feature ~path with
      | Some file
        when Spice_digest.Identity.equal (Feature.File.digest file) evidence ->
          Some mark
      | _ -> None)
  | Scope.Hunk { path; _ } -> (
      match Feature.find_file feature ~path with
      | Some file -> (
          match Feature.File.content file with
          | Feature.File.Text hunks -> (
              match
                List.filter
                  (fun hunk ->
                    Spice_digest.Identity.equal (hunk_evidence hunk) evidence)
                  hunks
              with
              | [ hunk ] ->
                  Some
                    (Mark.make ~scope:(Scope.of_hunk ~path hunk) ~state
                       ~evidence)
              | _ -> None)
          | Feature.File.Opaque _ -> None)
      | None -> None)
  | Scope.Line (side, path, line) -> (
      match Feature.find_file feature ~path with
      | Some file -> (
          match Feature.File.content file with
          | Feature.File.Text hunks -> (
              match find_line hunks ~side ~line with
              | Some found
                when Spice_digest.Identity.equal
                       (line_evidence ~side found)
                       evidence ->
                  Some mark
              | _ -> None)
          | Feature.File.Opaque _ -> None)
      | None -> None)

let carry_marks feature marks =
  List.fold_left
    (fun carried mark ->
      match carry_mark feature mark with
      | None -> carried
      | Some mark ->
          if
            List.exists
              (fun existing ->
                Scope.equal (Mark.scope existing) (Mark.scope mark))
              carried
          then carried
          else insert_mark carried mark)
    [] marks

let preserve_cursor old_t new_t =
  let old_target = old_t.cursor in
  let kept =
    match old_target with
    | Cursor.Cr index -> (
        match cr old_t index with
        | None -> None
        | Some occ -> (
            let digest = Spice_cr.Occurrence.digest occ in
            let path = Spice_cr.Occurrence.path occ in
            let same candidate =
              Spice_digest.Identity.equal
                (Spice_cr.Occurrence.digest candidate)
                digest
              && Spice_path.Rel.equal (Spice_cr.Occurrence.path candidate) path
            in
            let ordinal =
              let count = ref 0 in
              for j = 0 to index - 1 do
                if same old_t.crs.(j) then incr count
              done;
              !count
            in
            let matches =
              let found = ref [] in
              Array.iteri
                (fun j candidate -> if same candidate then found := j :: !found)
                new_t.crs;
              List.rev !found
            in
            match List.nth_opt matches ordinal with
            | Some index -> Some (Cursor.Cr index)
            | None -> (
                match List.rev matches with
                | index :: _ -> Some (Cursor.Cr index)
                | [] -> None)))
    | Cursor.Scope scope ->
        if Result.is_ok (scope_evidence new_t scope) then
          Some (Cursor.Scope scope)
        else None
  in
  match kept with
  | Some cursor -> cursor
  | None -> (
      let path_hint =
        match old_target with
        | Cursor.Scope scope -> Scope.path scope
        | Cursor.Cr index ->
            Option.map Spice_cr.Occurrence.path (cr old_t index)
      in
      match path_hint with
      | Some path when Option.is_some (Feature.find_file new_t.feature ~path) ->
          Cursor.Scope (Scope.File path)
      | _ -> (
          let old_stops = Array.of_list (stops old_t) in
          let new_stops = stops new_t in
          let old_index = position old_t old_stops in
          match
            List.nth_opt new_stops (min old_index (List.length new_stops - 1))
          with
          | Some target -> target
          | None -> Cursor.feature))

let refresh t ~feature ~crs =
  let refreshed =
    {
      feature;
      crs = Array.of_list crs;
      marks = carry_marks feature t.marks;
      verdict = t.verdict;
      cursor = t.cursor;
    }
  in
  { refreshed with cursor = preserve_cursor t refreshed }

(* Persistence restore: apply recorded state to a freshly loaded review with
   the same evidence rules as [refresh]. *)
let apply_persisted t ~marks ~verdict ~cursor =
  let t = { t with marks = carry_marks t.feature marks; verdict } in
  match set_cursor t cursor with Ok t -> t | Error _ -> t

(* Derived facts. Each is a fresh fold over the review; the inputs are
   review-sized, so recomputing per observer is cheaper than caching. *)

let feature t = t.feature
let cursor t = t.cursor

(* One review unit per hunk of a Text file, one per Opaque file. *)
let file_unit_scopes_of_file file =
  let path = Feature.File.path file in
  match Feature.File.content file with
  | Feature.File.Text hunks ->
      List.map (fun hunk -> Scope.of_hunk ~path hunk) hunks
  | Feature.File.Opaque _ -> [ Scope.File path ]

let file_unit_scopes t ~path =
  Option.map file_unit_scopes_of_file (Feature.find_file t.feature ~path)

let unit_scopes t = List.concat_map file_unit_scopes_of_file (Feature.files t.feature)

let files t = List.length (Feature.files t.feature)

let units t = List.length (unit_scopes t)

let reviewed_units t =
  List.length (List.filter (is_reviewed t) (unit_scopes t))

let open_crs t =
  Array.fold_left
    (fun open_crs occ ->
      match Spice_cr.Occurrence.comment occ with
      | Ok comment -> (
          match Spice_cr.status comment with
          | Spice_cr.Status.Open _ -> open_crs + 1
          | Spice_cr.Status.Resolved _ -> open_crs)
      | Error _ -> open_crs)
    0 t.crs

let progress t =
  let units = units t in
  if units = 0 then 1.
  else float_of_int (reviewed_units t) /. float_of_int units

let is_complete t = Int.equal (reviewed_units t) (units t)

let equal a b =
  Feature.equal a.feature b.feature
  && Int.equal (Array.length a.crs) (Array.length b.crs)
  && Array.for_all2 (fun x y -> Spice_cr.Occurrence.equal x y) a.crs b.crs
  && List.equal Mark.equal a.marks b.marks
  && Verdict.equal a.verdict b.verdict
  && Cursor.equal a.cursor b.cursor

let pp ppf t =
  let verdict =
    match verdict_freshness t with
    | `Pending -> "pending"
    | `Approved -> "approved"
    | `Stale -> "approved (stale)"
  in
  Format.fprintf ppf "review %s..%s: %d/%d reviewed, %d files, %d open CRs, %s"
    (Feature.base t.feature) (Feature.tip t.feature) (reviewed_units t)
    (units t) (files t) (open_crs t) verdict
