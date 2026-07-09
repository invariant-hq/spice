(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Review = Spice_review

let rel path = Spice_path.Rel.of_string_exn path
let expect_some msg = function Some value -> value | None -> failf "%s" msg

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Review.Error.pp error

let expect_error msg kind = function
  | Ok _ -> failf "%s: expected an error" msg
  | Error error ->
      let same =
        match (Review.Error.kind error, kind) with
        | Review.Error.Invalid_scope, Review.Error.Invalid_scope
        | Review.Error.Invalid_cursor, Review.Error.Invalid_cursor
        | Review.Error.Invalid_file, Review.Error.Invalid_file
        | Review.Error.Busy, Review.Error.Busy
        | Review.Error.Stale_snapshot, Review.Error.Stale_snapshot ->
            true
        | _ -> false
      in
      is_true ~msg same

let file ?(path = "lib/a.ml") ~before ~after () =
  expect_ok "file change"
    (Review.Feature.File.make ~path:(rel path) ~before ~after ())

let feature ?(base = "main") ?(tip = "WORKTREE") files =
  Review.Feature.v ~base ~tip files

let scan_crs ?(path = "lib/a.ml") text =
  Spice_cr.scan ~syntax:Spice_cr.Syntax.ocaml ~path:(rel path) ~text

let numbered n =
  String.concat "" (List.init n (fun i -> Printf.sprintf "line %02d\n" (i + 1)))

let edit_line text index replacement =
  String.concat "\n"
    (List.mapi
       (fun i line -> if i = index then replacement else line)
       (String.split_on_char '\n' text))

let insert_after text index replacement =
  String.concat "\n"
    (List.concat_map
       (fun (i, line) -> if i = index then [ line; replacement ] else [ line ])
       (List.mapi (fun i line -> (i, line)) (String.split_on_char '\n' text)))

(* Two edits 50 lines apart stay two hunks at the 12-line review context. *)
let simple_before = numbered 60
let simple_after = edit_line (edit_line simple_before 3 "EDIT A") 54 "EDIT B"

let simple_review () =
  let change =
    file ~before:(Some simple_before) ~after:(Some simple_after) ()
  in
  Review.v ~feature:(feature [ change ]) ~crs:[]

let first_hunk_scope review =
  let feature = Review.feature review in
  let changed = List.hd (Review.Feature.files feature) in
  match Review.Feature.File.content changed with
  | Review.Feature.File.Text (hunk :: _) ->
      Review.Scope.of_hunk ~path:(Review.Feature.File.path changed) hunk
  | _ -> failf "expected a text file with hunks"

let feature_construction_boundaries () =
  expect_error "file needs one side" Review.Error.Invalid_file
    (Review.Feature.File.make ~path:(rel "lib/missing.ml") ~before:None
       ~after:None ());
  expect_error "context must be non-negative" Review.Error.Invalid_file
    (Review.Feature.File.make ~context:(-1) ~path:(rel "lib/a.ml")
       ~before:(Some "a\n") ~after:(Some "b\n") ());
  expect_error "max edit distance must be non-negative" Review.Error.Invalid_file
    (Review.Feature.File.make ~max_edit_distance:(-1) ~path:(rel "lib/a.ml")
       ~before:(Some "a\n") ~after:(Some "b\n") ());
  let a_first =
    file ~path:"lib/a.ml" ~before:(Some "a\n") ~after:(Some "first\n") ()
  in
  let a_duplicate =
    file ~path:"lib/a.ml" ~before:(Some "a\n") ~after:(Some "duplicate\n") ()
  in
  let b = file ~path:"lib/b.ml" ~before:(Some "b\n") ~after:(Some "b'\n") () in
  let feature = feature [ b; a_first; a_duplicate ] in
  let files = Review.Feature.files feature in
  equal (list string) ~msg:"feature files are path sorted"
    [ "lib/a.ml"; "lib/b.ml" ]
    (List.map
       (fun file -> Spice_path.Rel.to_string (Review.Feature.File.path file))
       files);
  equal (option string) ~msg:"duplicate paths keep the first entry"
    (Some "first\n")
    (Option.bind
       (Review.Feature.find_file feature ~path:(rel "lib/a.ml"))
       Review.Feature.File.after)

(* Scopes *)

let scope_containment () =
  let path = rel "lib/a.ml" in
  let other = rel "lib/b.ml" in
  let hunk =
    Review.Scope.Hunk
      { path; old_start = 3; old_count = 4; new_start = 3; new_count = 5 }
  in
  is_true ~msg:"feature contains files"
    (Review.Scope.contains Review.Scope.Feature (Review.Scope.File path));
  is_true ~msg:"file contains its hunks"
    (Review.Scope.contains (Review.Scope.File path) hunk);
  is_true ~msg:"other files do not contain the hunk"
    (not (Review.Scope.contains (Review.Scope.File other) hunk));
  is_true ~msg:"hunk contains its new-side lines"
    (Review.Scope.contains hunk (Review.Scope.Line (Review.Scope.New, path, 7)));
  is_true ~msg:"hunk excludes lines outside its new range"
    (not
       (Review.Scope.contains hunk
          (Review.Scope.Line (Review.Scope.New, path, 8))));
  is_true ~msg:"hunk contains its old-side lines"
    (Review.Scope.contains hunk (Review.Scope.Line (Review.Scope.Old, path, 6)));
  is_true ~msg:"line contains only itself"
    (Review.Scope.contains
       (Review.Scope.Line (Review.Scope.New, path, 7))
       (Review.Scope.Line (Review.Scope.New, path, 7)))

(* Marks and effective marks *)

let marks_and_effective_marks () =
  let review = simple_review () in
  let path = rel "lib/a.ml" in
  let hunk = first_hunk_scope review in
  let review =
    expect_ok "mark file" (Review.mark_reviewed review (Review.Scope.File path))
  in
  is_true ~msg:"file mark covers its hunks" (Review.is_reviewed review hunk);
  let review = expect_ok "unmark hunk" (Review.mark_unreviewed review hunk) in
  is_true ~msg:"hunk override beats the file mark"
    (not (Review.is_reviewed review hunk));
  is_true ~msg:"file itself stays reviewed"
    (Review.is_reviewed review (Review.Scope.File path));
  let review =
    expect_ok "re-mark file"
      (Review.mark_reviewed review (Review.Scope.File path))
  in
  is_true ~msg:"covering mark replaces inner overrides"
    (Review.is_reviewed review hunk);
  expect_error "marking a missing file fails" Review.Error.Invalid_scope
    (Review.mark_reviewed review (Review.Scope.File (rel "lib/missing.ml")))

let summary_progress () =
  let review = simple_review () in
  equal int ~msg:"one file" 1 (Review.files review);
  equal int ~msg:"two units" 2 (Review.units review);
  equal int ~msg:"none reviewed" 0 (Review.reviewed_units review);
  is_true ~msg:"pending verdict"
    (match Review.verdict_freshness review with `Pending -> true | _ -> false);
  let hunk = first_hunk_scope review in
  let review = expect_ok "mark hunk" (Review.mark_reviewed review hunk) in
  equal int ~msg:"one reviewed unit" 1 (Review.reviewed_units review);
  is_true ~msg:"progress is a half"
    (Float.abs (Review.progress review -. 0.5) < 1e-9);
  is_true ~msg:"not complete" (not (Review.is_complete review))

let open_crs_counts_unresolved () =
  (* [open_crs] projects the unresolved CR count off the occurrence array:
     resolved (XCR) and unparseable comments do not count. *)
  let text =
    "let a = 1\n(* CR alice: fix this *)\n(* XCR alice: done *)\nlet b = 2\n"
  in
  let crs = scan_crs text in
  equal int ~msg:"both CR comments scanned" 2 (List.length crs);
  let change =
    file ~before:(Some "let a = 1\nlet b = 2\n") ~after:(Some text) ()
  in
  let review = Review.v ~feature:(feature [ change ]) ~crs in
  equal int ~msg:"only the open CR is counted" 1 (Review.open_crs review);
  equal int ~msg:"no CRs means none open" 0 (Review.open_crs (simple_review ()))

(* Verdict freshness *)

let verdict_staleness () =
  let review = simple_review () in
  let review = Review.approve review in
  is_true ~msg:"approved is fresh"
    (match Review.verdict_freshness review with
    | `Approved -> true
    | _ -> false);
  let changed =
    file ~before:(Some simple_before)
      ~after:(Some (edit_line simple_after 10 "ANOTHER EDIT"))
      ()
  in
  let review' = Review.refresh review ~feature:(feature [ changed ]) ~crs:[] in
  is_true ~msg:"content change stales the verdict"
    (match Review.verdict_freshness review' with `Stale -> true | _ -> false);
  let review' = Review.approve review' in
  is_true ~msg:"re-approval is fresh again"
    (match Review.verdict_freshness review' with
    | `Approved -> true
    | _ -> false)

(* Refresh carry-forward *)

let refresh_keeps_untouched_files () =
  let a = file ~path:"lib/a.ml" ~before:(Some "a\n") ~after:(Some "b\n") () in
  let b = file ~path:"lib/b.ml" ~before:(Some "x\n") ~after:(Some "y\n") () in
  let review = Review.v ~feature:(feature [ a; b ]) ~crs:[] in
  let review =
    expect_ok "mark a"
      (Review.mark_reviewed review (Review.Scope.File (rel "lib/a.ml")))
  in
  let b' = file ~path:"lib/b.ml" ~before:(Some "x\n") ~after:(Some "z\n") () in
  let review' = Review.refresh review ~feature:(feature [ a; b' ]) ~crs:[] in
  is_true ~msg:"untouched file keeps its mark"
    (Review.is_reviewed review' (Review.Scope.File (rel "lib/a.ml")));
  is_true ~msg:"edited file was never marked"
    (not (Review.is_reviewed review' (Review.Scope.File (rel "lib/b.ml"))))

let refresh_drops_edited_file_marks () =
  let review = simple_review () in
  let path = rel "lib/a.ml" in
  let review =
    expect_ok "mark file" (Review.mark_reviewed review (Review.Scope.File path))
  in
  let changed =
    file ~before:(Some simple_before)
      ~after:(Some (simple_after ^ "EXTRA\n"))
      ()
  in
  let review' = Review.refresh review ~feature:(feature [ changed ]) ~crs:[] in
  is_true ~msg:"edited file drops its mark"
    (not (Review.is_reviewed review' (Review.Scope.File path)))

let refresh_relocates_shifted_hunks () =
  (* The reviewed hunk's content is untouched; lines are inserted above it,
     so its position shifts. The mark must relocate by content evidence. *)
  let before =
    "a\n\
     b\n\
     c\n\
     d\n\
     e\n\
     f\n\
     g\n\
     h\n\
     i\n\
     j\n\
     k\n\
     l\n\
     m\n\
     n\n\
     o\n\
     p\n\
     q\n\
     r\n\
     s\n\
     t\n\
     u\n\
     v\n\
     w\n\
     1\n\
     2\n\
     3\n"
  in
  let after =
    "a\n\
     b\n\
     c\n\
     d\n\
     e\n\
     f\n\
     g\n\
     h\n\
     i\n\
     j\n\
     k\n\
     l\n\
     m\n\
     n\n\
     o\n\
     p\n\
     q\n\
     r\n\
     s\n\
     t\n\
     u\n\
     v\n\
     w\n\
     1\n\
     CHANGED\n\
     3\n"
  in
  let review =
    Review.v
      ~feature:(feature [ file ~before:(Some before) ~after:(Some after) () ])
      ~crs:[]
  in
  let hunk = first_hunk_scope review in
  let review = expect_ok "mark hunk" (Review.mark_reviewed review hunk) in
  let before' = "NEW\n" ^ before in
  let after' = "NEW\n" ^ after in
  let review' =
    Review.refresh review
      ~feature:(feature [ file ~before:(Some before') ~after:(Some after') () ])
      ~crs:[]
  in
  let hunk' = first_hunk_scope review' in
  is_true ~msg:"shifted hunk keeps its mark by evidence"
    (Review.is_reviewed review' hunk');
  is_true ~msg:"the relocated scope differs from the original"
    (not (Review.Scope.equal hunk hunk'))

let refresh_drops_ambiguous_hunks () =
  (* Two pure insertions of identical text produce identical changed-line
     evidence; the carried mark would be ambiguous and must drop. *)
  let base = numbered 60 in
  let after = insert_after base 5 "EXTRA" in
  let review =
    Review.v
      ~feature:(feature [ file ~before:(Some base) ~after:(Some after) () ])
      ~crs:[]
  in
  let hunk = first_hunk_scope review in
  let review = expect_ok "mark hunk" (Review.mark_reviewed review hunk) in
  let after' = insert_after after 50 "EXTRA" in
  let review' =
    Review.refresh review
      ~feature:(feature [ file ~before:(Some base) ~after:(Some after') () ])
      ~crs:[]
  in
  let feature' = Review.feature review' in
  let changed = List.hd (Review.Feature.files feature') in
  match Review.Feature.File.content changed with
  | Review.Feature.File.Text hunks ->
      equal int ~msg:"two hunks after refresh" 2 (List.length hunks);
      List.iter
        (fun hunk ->
          is_true ~msg:"ambiguous hunk marks drop"
            (not
               (Review.is_reviewed review'
                  (Review.Scope.of_hunk
                     ~path:(Review.Feature.File.path changed)
                     hunk))))
        hunks
  | _ -> failf "expected text hunks"

let refresh_reanchors_cr_cursor () =
  let text = "let a = 1\n(* CR alice: rename this *)\nlet b = 2\n" in
  let crs = scan_crs text in
  equal int ~msg:"one CR scanned" 1 (List.length crs);
  let change = file ~before:(Some "let a = 1\n") ~after:(Some text) () in
  let review = Review.v ~feature:(feature [ change ]) ~crs in
  let review =
    expect_ok "select cr" (Review.set_cursor review (Review.Cursor.Cr 0))
  in
  (* New text shifts the CR down. *)
  let text' =
    "let z = 0\nlet a = 1\n(* CR alice: rename this *)\nlet b = 2\n"
  in
  let crs' = scan_crs text' in
  let change' = file ~before:(Some "let a = 1\n") ~after:(Some text') () in
  let review' =
    Review.refresh review ~feature:(feature [ change' ]) ~crs:crs'
  in
  (match Review.cursor review' with
  | Review.Cursor.Cr 0 -> ()
  | _ ->
      failf "expected the cursor to re-anchor to CR 0, got %a" Review.Cursor.pp
        (Review.cursor review'));
  (* When the CR vanishes the cursor falls back to the containing file. *)
  let text'' = "let a = 1\nlet b = 2\n" in
  let review'' =
    Review.refresh review
      ~feature:
        (feature [ file ~before:(Some "let a = 1\n") ~after:(Some text'') () ])
      ~crs:[]
  in
  match Review.cursor review'' with
  | Review.Cursor.Scope scope ->
      is_true ~msg:"cursor falls back to the file"
        (Review.Scope.equal scope (Review.Scope.File (rel "lib/a.ml")))
  | Review.Cursor.Cr _ ->
      failf "unexpected cursor %a" Review.Cursor.pp (Review.cursor review'')

(* Navigation *)

let navigation_order () =
  let text = "let a = 1\n(* CR alice: rename this *)\nlet b = 2\n" in
  let crs = scan_crs text in
  let change =
    file ~before:(Some "let a = 1\nlet b = 2\n") ~after:(Some text) ()
  in
  let review = Review.v ~feature:(feature [ change ]) ~crs in
  (* feature -> file -> hunk(s) -> cr *)
  let step review = Review.move_cursor review Review.Cursor.Next in
  let review = step review in
  (match Review.cursor review with
  | Review.Cursor.Scope scope ->
      is_true ~msg:"first stop is the file"
        (Review.Scope.equal scope (Review.Scope.File (rel "lib/a.ml")))
  | _ -> failf "expected a scope");
  let review = step review in
  (match Review.cursor review with
  | Review.Cursor.Scope scope -> (
      match scope with
      | Review.Scope.Hunk _ -> ()
      | _ -> failf "expected a hunk stop")
  | _ -> failf "expected a scope");
  let review = Review.move_cursor review Review.Cursor.Next_cr in
  (match Review.cursor review with
  | Review.Cursor.Cr 0 -> ()
  | _ -> failf "expected the CR stop");
  (* Without wrap the cursor stays at the last stop. *)
  let review = step review in
  let review = step review in
  match Review.cursor review with
  | Review.Cursor.Cr 0 -> ()
  | _ ->
      failf "expected to stay at the CR, got %a" Review.Cursor.pp
        (Review.cursor review)

let navigation_jumps_and_wraps () =
  let a =
    file ~path:"lib/a.ml" ~before:(Some "let a = 1\n")
      ~after:(Some "let a = 2\n") ()
  in
  let b =
    file ~path:"lib/b.ml" ~before:(Some "let b = 1\n")
      ~after:(Some "let b = 2\n") ()
  in
  let crs = scan_crs ~path:"notes.ml" "(* CR: outside changed files *)\n" in
  let review = Review.v ~feature:(feature [ b; a ]) ~crs in
  let expect_cursor msg expected review =
    is_true ~msg (Review.Cursor.equal expected (Review.cursor review))
  in
  let file_a = Review.Cursor.Scope (Review.Scope.File (rel "lib/a.ml")) in
  let file_b = Review.Cursor.Scope (Review.Scope.File (rel "lib/b.ml")) in
  let outside_cr = Review.Cursor.Cr 0 in
  let review = Review.move_cursor review Review.Cursor.Next_file in
  expect_cursor "Next_file lands on the first file" file_a review;
  let review = Review.move_cursor review Review.Cursor.Next_file in
  expect_cursor "Next_file skips to the next file" file_b review;
  let review = Review.move_cursor review Review.Cursor.Previous_file in
  expect_cursor "Previous_file returns to the previous file" file_a review;
  let review = Review.move_cursor review Review.Cursor.First in
  expect_cursor "First returns to feature" Review.Cursor.feature review;
  let review = Review.move_cursor review Review.Cursor.Next_cr in
  expect_cursor "Next_cr reaches CRs outside changed files" outside_cr review;
  let review = Review.move_cursor review Review.Cursor.Previous_cr in
  expect_cursor "Previous_cr without wrap stays on the first CR" outside_cr
    review;
  let review = Review.move_cursor review Review.Cursor.Last in
  expect_cursor "Last reaches the final stop" outside_cr review;
  let review = Review.move_cursor ~wrap:true review Review.Cursor.Next in
  expect_cursor "Next wraps from the final stop to feature" Review.Cursor.feature
    review;
  let review = Review.move_cursor ~wrap:true review Review.Cursor.Previous in
  expect_cursor "Previous wraps from feature to the final stop" outside_cr review

(* Live protocol *)

let live_debounce_and_load () =
  let review = simple_review () in
  let live = Review.Live.make ~review ~fingerprint:"fp0" () in
  let live, actions =
    Review.Live.step live (Review.Live.Fs_changed { now = 0. })
  in
  let request, seconds =
    match actions with
    | [ Review.Live.Sleep { request; seconds } ] -> (request, seconds)
    | _ -> failf "expected a sleep action"
  in
  is_true ~msg:"default debounce" (Float.abs (seconds -. 0.5) < 1e-9);
  (* A burst extends the deadline; the early tick re-arms. *)
  let live, actions =
    Review.Live.step live (Review.Live.Fs_changed { now = 0.3 })
  in
  is_true ~msg:"burst schedules nothing new" (List.is_empty actions);
  let live, actions =
    Review.Live.step live (Review.Live.Tick { now = 0.5; request })
  in
  (match actions with
  | [ Review.Live.Sleep { seconds; _ } ] ->
      is_true ~msg:"re-armed for the remainder"
        (Float.abs (seconds -. 0.3) < 1e-9)
  | _ -> failf "expected a re-armed sleep");
  let live, actions =
    Review.Live.step live (Review.Live.Tick { now = 0.81; request })
  in
  let load_request =
    match actions with
    | [ Review.Live.Load { request; known = Some "fp0" } ] -> request
    | _ -> failf "expected a load action against fp0"
  in
  (* A stale tick is ignored while loading. *)
  let live, actions =
    Review.Live.step live (Review.Live.Tick { now = 1.0; request })
  in
  is_true ~msg:"stale tick ignored" (List.is_empty actions);
  (* Unchanged load returns to idle. *)
  let live, actions =
    Review.Live.step live (Review.Live.Loaded (load_request, Ok `Unchanged))
  in
  is_true ~msg:"unchanged load is quiet" (List.is_empty actions);
  ignore live

let live_replace_and_dirty_reload () =
  let review = simple_review () in
  let live = Review.Live.make ~review ~fingerprint:"fp0" () in
  let live, actions =
    Review.Live.step live (Review.Live.Fs_changed { now = 0. })
  in
  let sleep_request =
    match actions with
    | [ Review.Live.Sleep { request; _ } ] -> request
    | _ -> failf "expected sleep"
  in
  let live, actions =
    Review.Live.step live
      (Review.Live.Tick { now = 0.5; request = sleep_request })
  in
  let load_request =
    match actions with
    | [ Review.Live.Load { request; _ } ] -> request
    | _ -> failf "expected load"
  in
  (* Changes arrive while loading: reload once the load completes. *)
  let live, _ = Review.Live.step live (Review.Live.Fs_changed { now = 0.6 }) in
  let changed =
    file ~before:(Some "a\n") ~after:(Some "b\n") ~path:"lib/c.ml" ()
  in
  let load =
    { Review.Live.feature = feature [ changed ]; crs = []; fingerprint = "fp1" }
  in
  let live, actions =
    Review.Live.step live (Review.Live.Loaded (load_request, Ok (`Loaded load)))
  in
  (match actions with
  | [ Review.Live.Replace replaced; Review.Live.Load { known = Some "fp1"; _ } ]
    ->
      is_true ~msg:"replaced review has the new feature"
        (Review.Feature.equal (Review.feature replaced) (feature [ changed ]))
  | _ -> failf "expected replace followed by a dirty reload");
  ignore live

let live_mutation_guard () =
  let review = simple_review () in
  let live = Review.Live.make ~review ~fingerprint:"fp0" () in
  expect_error "stale mutation refused" Review.Error.Stale_snapshot
    (Result.map
       (fun _ -> ())
       (Review.Live.mutation_started live ~fingerprint:"other"));
  let live, request =
    expect_ok "mutation starts"
      (Review.Live.mutation_started live ~fingerprint:"fp0")
  in
  expect_error "second mutation refused" Review.Error.Busy
    (Result.map
       (fun _ -> ())
       (Review.Live.mutation_started live ~fingerprint:"fp0"));
  (* Watch events during a mutation are ignored. *)
  let live, actions =
    Review.Live.step live (Review.Live.Fs_changed { now = 0. })
  in
  is_true ~msg:"watching pauses during mutation" (List.is_empty actions);
  (* Failure clears the fingerprint so the next cycle recovers. *)
  let live, outcome =
    Review.Live.mutation_loaded live request (Error "write failed")
  in
  (match outcome with
  | `Failed _ -> ()
  | _ -> failf "expected a failed mutation");
  is_true ~msg:"fingerprint cleared on failure"
    (Option.is_none (Review.Live.fingerprint live));
  (* Recovery load runs unconditionally. *)
  let live, actions =
    Review.Live.step live (Review.Live.Fs_changed { now = 1. })
  in
  let sleep_request =
    match actions with
    | [ Review.Live.Sleep { request; _ } ] -> request
    | _ -> failf "expected sleep"
  in
  let _, actions =
    Review.Live.step live
      (Review.Live.Tick { now = 1.5; request = sleep_request })
  in
  match actions with
  | [ Review.Live.Load { known = None; _ } ] -> ()
  | _ -> failf "expected an unconditional load"

(* Persistence *)

let persist_round_trip_and_validation () =
  let review = simple_review () in
  let hunk = first_hunk_scope review in
  let review = expect_ok "mark hunk" (Review.mark_reviewed review hunk) in
  let review = Review.approve review in
  let review =
    expect_ok "set cursor" (Review.set_cursor review (Review.Cursor.Scope hunk))
  in
  let record = Review.Persist.of_review review in
  let encoded =
    match Jsont_bytesrw.encode_string Review.Persist.jsont record with
    | Ok text -> text
    | Error message -> failf "encode failed: %s" message
  in
  let decoded =
    match Jsont_bytesrw.decode_string Review.Persist.jsont encoded with
    | Ok record -> record
    | Error message -> failf "decode failed: %s" message
  in
  (* Restore onto identical content: everything survives. *)
  let fresh = simple_review () in
  let restored = Review.Persist.restore decoded fresh in
  is_true ~msg:"mark restored" (Review.is_reviewed restored hunk);
  is_true ~msg:"approval restored fresh"
    (match Review.verdict_freshness restored with
    | `Approved -> true
    | _ -> false);
  is_true ~msg:"cursor restored"
    (Review.Cursor.equal (Review.cursor restored) (Review.Cursor.Scope hunk));
  (* Restore onto changed content: stale marks drop, approval shows stale. *)
  let changed =
    file ~before:(Some simple_before)
      ~after:(Some (edit_line simple_after 10 "DIFFERENT"))
      ()
  in
  let fresh' = Review.v ~feature:(feature [ changed ]) ~crs:[] in
  let restored' = Review.Persist.restore decoded fresh' in
  is_true ~msg:"stale approval is visible"
    (match Review.verdict_freshness restored' with
    | `Stale -> true
    | _ -> false);
  (* Restore against another base restores nothing. *)
  let other_base =
    Review.v ~feature:(feature ~base:"other" [ changed ]) ~crs:[]
  in
  let restored'' = Review.Persist.restore decoded other_base in
  is_true ~msg:"other base keeps pending"
    (match Review.verdict_freshness restored'' with
    | `Pending -> true
    | _ -> false);
  equal int ~msg:"other base restores no marks" 0
    (List.length (Review.marks restored''))

let persist_rejects_future_versions () =
  let json =
    {|{"version": 2, "base": "main", "marks": [], "verdict": {"kind": "pending"}, "cursor": {"kind": "scope", "scope": {"kind": "feature"}}}|}
  in
  match Jsont_bytesrw.decode_string Review.Persist.jsont json with
  | Ok _ -> failf "expected a version error"
  | Error _ -> ()

(* Opaque files *)

let opaque_files_are_whole_file_units () =
  let binary =
    expect_some "binary change"
      (Result.to_option
         (Review.Feature.File.make ~path:(rel "img/logo.png")
            ~before:(Some "\xff\xfe\x00binary")
            ~after:(Some "\xff\xfe\x01binary") ()))
  in
  (match Review.Feature.File.content binary with
  | Review.Feature.File.Opaque `Binary -> ()
  | _ -> failf "expected opaque binary content");
  let review = Review.v ~feature:(feature [ binary ]) ~crs:[] in
  equal int ~msg:"one whole-file unit" 1 (Review.units review);
  let review =
    expect_ok "mark opaque file"
      (Review.mark_reviewed review (Review.Scope.File (rel "img/logo.png")))
  in
  is_true ~msg:"opaque file unit reviewed" (Review.is_complete review)

let () =
  run "spice.review"
    [
      group "features"
        [ test "construction boundaries" feature_construction_boundaries ];
      group "scopes" [ test "containment" scope_containment ];
      group "marks"
        [
          test "explicit and effective marks" marks_and_effective_marks;
          test "summary progress" summary_progress;
          test "open CR count excludes resolved" open_crs_counts_unresolved;
        ];
      group "verdict" [ test "staleness" verdict_staleness ];
      group "refresh"
        [
          test "keeps untouched files" refresh_keeps_untouched_files;
          test "drops edited file marks" refresh_drops_edited_file_marks;
          test "relocates shifted hunks" refresh_relocates_shifted_hunks;
          test "drops ambiguous hunks" refresh_drops_ambiguous_hunks;
          test "re-anchors CR cursors" refresh_reanchors_cr_cursor;
        ];
      group "navigation"
        [
          test "canonical order" navigation_order;
          test "jumps and wrapping" navigation_jumps_and_wraps;
        ];
      group "live"
        [
          test "debounce and load" live_debounce_and_load;
          test "replace and dirty reload" live_replace_and_dirty_reload;
          test "mutation guard" live_mutation_guard;
        ];
      group "persist"
        [
          test "round trip and validation" persist_round_trip_and_validation;
          test "rejects future versions" persist_rejects_future_versions;
          test "opaque files are whole-file units"
            opaque_files_are_whole_file_units;
        ];
    ]
