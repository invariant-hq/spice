(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type review = Review.t

type mark_record = {
  scope : Scope.t;
  state : Mark.state;
  evidence : Spice_digest.Identity.t;
}

type t = {
  base : string;
  marks : mark_record list;
  verdict : Verdict.t;
  cursor : Cursor.t;
}

let version = 1
let decode_error message = Jsont.Error.msg Jsont.Meta.none message

let rel_path_jsont =
  Jsont.map ~kind:"relative path"
    ~dec:(fun raw ->
      match Spice_path.Rel.of_string raw with
      | Ok path -> path
      | Error error -> decode_error (Spice_path.Error.message error))
    ~enc:Spice_path.Rel.to_string Jsont.string

let side_jsont =
  Jsont.enum ~kind:"diff side" [ ("old", Scope.Old); ("new", Scope.New) ]

let state_jsont =
  Jsont.enum ~kind:"mark state"
    [ ("reviewed", Mark.Reviewed); ("unreviewed", Mark.Unreviewed) ]

let scope_jsont =
  let feature_case =
    Jsont.Object.map ~kind:"feature scope" Scope.Feature
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "feature" ~dec:Fun.id
  in
  let file_case =
    Jsont.Object.map ~kind:"file scope" (fun path -> Scope.File path)
    |> Jsont.Object.mem "path" rel_path_jsont ~enc:(function
      | Scope.File path -> path
      | Scope.Feature | Scope.Hunk _ | Scope.Line _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "file" ~dec:Fun.id
  in
  let hunk_case =
    Jsont.Object.map ~kind:"hunk scope"
      (fun path old_start old_count new_start new_count ->
        Scope.Hunk { path; old_start; old_count; new_start; new_count })
    |> Jsont.Object.mem "path" rel_path_jsont ~enc:(function
      | Scope.Hunk { path; _ } -> path
      | Scope.Feature | Scope.File _ | Scope.Line _ -> assert false)
    |> Jsont.Object.mem "old_start" Jsont.int ~enc:(function
      | Scope.Hunk { old_start; _ } -> old_start
      | Scope.Feature | Scope.File _ | Scope.Line _ -> assert false)
    |> Jsont.Object.mem "old_count" Jsont.int ~enc:(function
      | Scope.Hunk { old_count; _ } -> old_count
      | Scope.Feature | Scope.File _ | Scope.Line _ -> assert false)
    |> Jsont.Object.mem "new_start" Jsont.int ~enc:(function
      | Scope.Hunk { new_start; _ } -> new_start
      | Scope.Feature | Scope.File _ | Scope.Line _ -> assert false)
    |> Jsont.Object.mem "new_count" Jsont.int ~enc:(function
      | Scope.Hunk { new_count; _ } -> new_count
      | Scope.Feature | Scope.File _ | Scope.Line _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "hunk" ~dec:Fun.id
  in
  let line_case =
    Jsont.Object.map ~kind:"line scope" (fun side path line ->
        Scope.Line (side, path, line))
    |> Jsont.Object.mem "side" side_jsont ~enc:(function
      | Scope.Line (side, _, _) -> side
      | Scope.Feature | Scope.File _ | Scope.Hunk _ -> assert false)
    |> Jsont.Object.mem "path" rel_path_jsont ~enc:(function
      | Scope.Line (_, path, _) -> path
      | Scope.Feature | Scope.File _ | Scope.Hunk _ -> assert false)
    |> Jsont.Object.mem "line" Jsont.int ~enc:(function
      | Scope.Line (_, _, line) -> line
      | Scope.Feature | Scope.File _ | Scope.Hunk _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "line" ~dec:Fun.id
  in
  let cases =
    List.map Jsont.Object.Case.make
      [ feature_case; file_case; hunk_case; line_case ]
  in
  let enc_case = function
    | Scope.Feature -> Jsont.Object.Case.value feature_case Scope.Feature
    | Scope.File _ as scope -> Jsont.Object.Case.value file_case scope
    | Scope.Hunk _ as scope -> Jsont.Object.Case.value hunk_case scope
    | Scope.Line _ as scope -> Jsont.Object.Case.value line_case scope
  in
  Jsont.Object.map ~kind:"scope" Fun.id
  |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let mark_jsont =
  Jsont.Object.map ~kind:"review mark" (fun scope state evidence ->
      { scope; state; evidence })
  |> Jsont.Object.mem "scope" scope_jsont ~enc:(fun mark -> mark.scope)
  |> Jsont.Object.mem "state" state_jsont ~enc:(fun mark -> mark.state)
  |> Jsont.Object.mem "evidence" Spice_digest.Identity.jsont ~enc:(fun mark ->
      mark.evidence)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let verdict_jsont =
  let pending_case =
    Jsont.Object.map ~kind:"pending verdict" Verdict.Pending
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "pending" ~dec:Fun.id
  in
  let approved_case =
    Jsont.Object.map ~kind:"approved verdict" (fun feature ->
        Verdict.Approved { feature })
    |> Jsont.Object.mem "feature" Spice_digest.Identity.jsont ~enc:(function
      | Verdict.Approved { feature } -> feature
      | Verdict.Pending -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "approved" ~dec:Fun.id
  in
  let cases = List.map Jsont.Object.Case.make [ pending_case; approved_case ] in
  let enc_case = function
    | Verdict.Pending -> Jsont.Object.Case.value pending_case Verdict.Pending
    | Verdict.Approved _ as verdict ->
        Jsont.Object.Case.value approved_case verdict
  in
  Jsont.Object.map ~kind:"verdict" Fun.id
  |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let cursor_jsont =
  let scope_case =
    Jsont.Object.map ~kind:"scope cursor" (fun scope -> Cursor.Scope scope)
    |> Jsont.Object.mem "scope" scope_jsont ~enc:(function
      | Cursor.Scope scope -> scope
      | Cursor.Cr _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "scope" ~dec:Fun.id
  in
  let cr_case =
    Jsont.Object.map ~kind:"cr cursor" (fun index -> Cursor.Cr index)
    |> Jsont.Object.mem "index" Jsont.int ~enc:(function
      | Cursor.Cr index -> index
      | Cursor.Scope _ -> assert false)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
    |> Jsont.Object.Case.map "cr" ~dec:Fun.id
  in
  let cases = List.map Jsont.Object.Case.make [ scope_case; cr_case ] in
  let enc_case = function
    | Cursor.Scope _ as cursor -> Jsont.Object.Case.value scope_case cursor
    | Cursor.Cr _ as cursor -> Jsont.Object.Case.value cr_case cursor
  in
  Jsont.Object.map ~kind:"cursor" Fun.id
  |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let jsont =
  Jsont.Object.map ~kind:"review state"
    (fun decoded_version base marks verdict cursor ->
      if not (Int.equal decoded_version version) then
        decode_error
          (Printf.sprintf "unsupported review state version %d" decoded_version)
      else { base; marks; verdict; cursor })
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun _ -> version)
  |> Jsont.Object.mem "base" Jsont.string ~enc:(fun record -> record.base)
  |> Jsont.Object.mem "marks" (Jsont.list mark_jsont) ~enc:(fun record ->
      record.marks)
  |> Jsont.Object.mem "verdict" verdict_jsont ~enc:(fun record ->
      record.verdict)
  |> Jsont.Object.mem "cursor" cursor_jsont ~enc:(fun record -> record.cursor)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let of_review review =
  {
    base = Feature.base (Review.feature review);
    marks =
      List.map
        (fun mark ->
          {
            scope = Mark.scope mark;
            state = Mark.state mark;
            evidence = Mark.evidence mark;
          })
        (Review.marks review);
    verdict = Review.verdict review;
    cursor = Review.cursor review;
  }

let restore record review =
  if not (String.equal record.base (Feature.base (Review.feature review))) then
    review
  else
    let marks =
      List.map
        (fun { scope; state; evidence } -> Mark.make ~scope ~state ~evidence)
        record.marks
    in
    Review.apply_persisted review ~marks ~verdict:record.verdict
      ~cursor:record.cursor
