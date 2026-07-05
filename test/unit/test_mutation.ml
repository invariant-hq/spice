(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module M = Spice_mutation
module Edit = Spice_edit
module W = Spice_workspace
module Path = Spice_path

let rel text = Path.Rel.of_string_exn text
let abs text = Path.Abs.of_string_exn text
let root = W.Root.make (abs "/workspace")
let session = Spice_session.Id.of_string "session-1"
let turn = Spice_session.Turn.Id.of_string "turn-1"
let other_turn = Spice_session.Turn.Id.of_string "turn-2"
let execution = Spice_session.Tool_claim.Id.of_string "tool_exec-1"
let image = testable ~pp:M.Image.pp ~equal:M.Image.equal ()
let record = testable ~pp:M.Record.pp ~equal:M.Record.equal ()
let scope = testable ~pp:M.Scope.pp ~equal:M.Scope.equal ()
let text_image contents = M.Image.of_target (Edit.Observed.Text contents)

let tool_source =
  M.Change.Tool { execution; call_id = "call-1"; tool = "edit_file" }

let change ?(turn = turn) ?(op = M.Change.Modify) ~path ~before ~after index =
  M.Change.make
    ~id:(M.Change.derive_id ~execution ~path:(rel path) ~index)
    ~session ~turn ~source:tool_source ~path:(rel path) ~op ~before ~after
    ~additions:1 ~deletions:0 ~revertability:M.Change.Revertable ()

let check_entry ~msg (entry : M.Change.Net.entry) ~path ~before ~after
    ~contiguous ~sources =
  equal string ~msg:(msg ^ " path") path
    (Path.Rel.to_string entry.M.Change.Net.path);
  equal image ~msg:(msg ^ " before") before entry.M.Change.Net.before;
  equal image ~msg:(msg ^ " after") after entry.M.Change.Net.after;
  equal bool ~msg:(msg ^ " contiguous") contiguous entry.M.Change.Net.contiguous;
  equal (list string) ~msg:(msg ^ " sources") sources
    (List.map M.Change.Id.to_string entry.M.Change.Net.sources)

let roundtrip msg codec value =
  match Jsont.Json.encode codec value with
  | Error error -> failf "%s: encode failed: %s" msg error
  | Ok json -> (
      match Jsont.Json.decode codec json with
      | Error error -> failf "%s: decode failed: %s" msg error
      | Ok value -> value)

let net_endpoints () =
  let a = text_image "a\n" in
  let b = text_image "b\n" in
  let c = text_image "c\n" in
  let changes =
    [
      change ~path:"file.ml" ~before:a ~after:b 0;
      change ~path:"file.ml" ~before:b ~after:c 1;
    ]
  in
  match M.Change.net changes with
  | [ entry ] ->
      check_entry ~msg:"chained modifies" entry ~path:"file.ml" ~before:a
        ~after:c ~contiguous:true
        ~sources:
          (List.map
             (fun change -> M.Change.Id.to_string (M.Change.id change))
             changes)
  | entries -> failf "expected one net entry, got %d" (List.length entries)

let net_drops_noops () =
  let a = text_image "a\n" in
  let b = text_image "b\n" in
  let changes =
    [
      change ~path:"file.ml" ~before:a ~after:b 0;
      change ~path:"file.ml" ~before:b ~after:a 1;
    ]
  in
  equal int ~msg:"A->B->A nets to nothing" 0
    (List.length (M.Change.net changes))

let net_contiguity_flag () =
  let a = text_image "a\n" in
  let b = text_image "b\n" in
  let c = text_image "c\n" in
  let d = text_image "d\n" in
  let changes =
    [
      change ~path:"file.ml" ~before:a ~after:b 0;
      change ~path:"file.ml" ~before:c ~after:d 1;
    ]
  in
  match M.Change.net changes with
  | [ entry ] ->
      equal image ~msg:"endpoint before" a entry.M.Change.Net.before;
      equal image ~msg:"endpoint after" d entry.M.Change.Net.after;
      equal bool ~msg:"discontinuous chain flagged" false
        entry.M.Change.Net.contiguous
  | entries -> failf "expected one net entry, got %d" (List.length entries)

let net_move_expansion () =
  let a = text_image "a\n" in
  let move =
    change ~path:"new.ml"
      ~op:(M.Change.Move { from = rel "old.ml" })
      ~before:a ~after:a 0
  in
  match M.Change.net [ move ] with
  | [ source; destination ] ->
      check_entry ~msg:"move source" source ~path:"old.ml" ~before:a
        ~after:M.Image.Missing ~contiguous:true
        ~sources:[ M.Change.Id.to_string (M.Change.id move) ];
      check_entry ~msg:"move destination" destination ~path:"new.ml"
        ~before:M.Image.Missing ~after:a ~contiguous:true
        ~sources:[ M.Change.Id.to_string (M.Change.id move) ]
  | entries -> failf "expected two net entries, got %d" (List.length entries)

let net_create_then_move () =
  let a = text_image "a\n" in
  let changes =
    [
      change ~path:"old.ml" ~op:M.Change.Create ~before:M.Image.Missing ~after:a
        0;
      change ~path:"new.ml"
        ~op:(M.Change.Move { from = rel "old.ml" })
        ~before:a ~after:a 1;
    ]
  in
  match M.Change.net changes with
  | [ entry ] ->
      equal string ~msg:"only the destination survives" "new.ml"
        (Path.Rel.to_string entry.M.Change.Net.path);
      equal image ~msg:"created at destination" a entry.M.Change.Net.after
  | entries -> failf "expected one net entry, got %d" (List.length entries)

let net_move_chain () =
  let a = text_image "a\n" in
  let changes =
    [
      change ~path:"b.ml"
        ~op:(M.Change.Move { from = rel "a.ml" })
        ~before:a ~after:a 0;
      change ~path:"c.ml"
        ~op:(M.Change.Move { from = rel "b.ml" })
        ~before:a ~after:a 1;
    ]
  in
  match M.Change.net changes with
  | [ source; destination ] ->
      equal string ~msg:"chain source" "a.ml"
        (Path.Rel.to_string source.M.Change.Net.path);
      equal image ~msg:"chain source deleted" M.Image.Missing
        source.M.Change.Net.after;
      equal string ~msg:"chain destination" "c.ml"
        (Path.Rel.to_string destination.M.Change.Net.path);
      equal image ~msg:"chain destination created" a
        destination.M.Change.Net.after
  | entries -> failf "expected two net entries, got %d" (List.length entries)

let scope_selection () =
  let a = text_image "a\n" in
  let b = text_image "b\n" in
  let in_turn = change ~path:"one.ml" ~before:a ~after:b 0 in
  let other = change ~turn:other_turn ~path:"two.ml" ~before:a ~after:b 1 in
  let move =
    change ~path:"moved.ml"
      ~op:(M.Change.Move { from = rel "one.ml" })
      ~before:b ~after:b 2
  in
  let changes = [ in_turn; other; move ] in
  equal int ~msg:"session scope selects all" 3
    (List.length (M.Scope.select M.Scope.Session changes));
  equal int ~msg:"turn scope filters" 2
    (List.length (M.Scope.select (M.Scope.Turn turn) changes));
  equal int ~msg:"turns scope unions the set" 3
    (List.length (M.Scope.select (M.Scope.Turns [ turn; other_turn ]) changes));
  equal int ~msg:"turns scope of one turn matches turn scope" 2
    (List.length (M.Scope.select (M.Scope.Turns [ turn ]) changes));
  equal int ~msg:"turns scope selects the other turn's row" 1
    (List.length (M.Scope.select (M.Scope.Turns [ other_turn ]) changes));
  equal int ~msg:"empty turns scope selects nothing" 0
    (List.length (M.Scope.select (M.Scope.Turns []) changes));
  equal int ~msg:"change scope selects one" 1
    (List.length (M.Scope.select (M.Scope.Change (M.Change.id other)) changes));
  equal int ~msg:"path scope includes move sources" 2
    (List.length (M.Scope.select (M.Scope.Path (rel "one.ml")) changes))

let change_totals () =
  let a = text_image "a\n" in
  let b = text_image "b\n" in
  let changes =
    [
      change ~path:"one.ml" ~before:a ~after:b 0;
      change ~path:"one.ml" ~before:b ~after:a 1;
      change ~path:"two.ml" ~before:a ~after:b 2;
    ]
  in
  let totals = M.Change.totals changes in
  equal int ~msg:"distinct files" 2 totals.M.Change.files;
  equal int ~msg:"summed additions" 3 totals.M.Change.total_additions;
  equal int ~msg:"summed deletions" 0 totals.M.Change.total_deletions

(* In-memory workspace for plan/lower tests. *)

let read_of fs path =
  match List.assoc_opt (Path.Rel.to_string path) fs with
  | Some contents -> Edit.Observed.Text contents
  | None -> Edit.Observed.Missing

let resolve path = Ok (W.Path.make ~root path)

let blob_of contents_list identity =
  List.find_opt
    (fun contents ->
      Spice_digest.Identity.equal
        (Spice_digest.Identity.of_contents contents)
        identity)
    contents_list

let apply_to_fs fs edit =
  let observed path =
    match List.assoc_opt (W.Path.display path) fs with
    | Some contents -> Edit.Observed.Text contents
    | None -> Edit.Observed.Missing
  in
  let io =
    {
      Edit.Apply.with_write_lock = (fun _ f -> f ());
      revalidate = (fun path -> Ok path);
      read = (fun path -> Ok (observed path));
      commit = (fun ~path:_ ~before:_ ~after:_ -> Ok ());
    }
  in
  match Edit.apply ~io ~workspace:(W.single root) edit with
  | Error error -> failf "apply_to_fs: %s" (Edit.Apply_error.message error)
  | Ok result ->
      List.fold_left
        (fun fs entry ->
          let path = W.Path.display (Edit.Result.Entry.target_path entry) in
          match Edit.Result.Entry.after entry with
          | Edit.Observed.Text contents ->
              (path, contents) :: List.remove_assoc path fs
          | Edit.Observed.Missing | Edit.Observed.Other ->
              List.remove_assoc path fs)
        fs
        (Edit.Result.entries result)

let revert_plan_and_lower () =
  let original = "original\n" in
  let modified = "modified\n" in
  let created = "created\n" in
  let deleted = "deleted\n" in
  let changes =
    [
      change ~path:"modified.ml" ~before:(text_image original)
        ~after:(text_image modified) 0;
      change ~path:"created.ml" ~op:M.Change.Create ~before:M.Image.Missing
        ~after:(text_image created) 1;
      change ~path:"deleted.ml" ~op:M.Change.Delete ~before:(text_image deleted)
        ~after:M.Image.Missing 2;
    ]
  in
  let fs = [ ("modified.ml", modified); ("created.ml", created) ] in
  let plan = M.Revert.plan ~read:(read_of fs) ~scope:M.Scope.Session changes in
  equal int ~msg:"no problems" 0 (List.length plan.M.Revert.problems);
  equal int ~msg:"three ready paths" 3 (List.length plan.M.Revert.ready);
  let blob = blob_of [ original; deleted ] in
  match M.Revert.lower plan ~resolve ~blob with
  | Error problems ->
      failf "lower failed with %d problems" (List.length problems)
  | Ok edit ->
      let reverted = apply_to_fs fs edit in
      equal (option string) ~msg:"modified restored" (Some original)
        (List.assoc_opt "modified.ml" reverted);
      equal (option string) ~msg:"created removed" None
        (List.assoc_opt "created.ml" reverted);
      equal (option string) ~msg:"deleted restored" (Some deleted)
        (List.assoc_opt "deleted.ml" reverted)

let revert_stale_refusal () =
  let original = "original\n" in
  let modified = "modified\n" in
  let drifted = "drifted\n" in
  let changes =
    [
      change ~path:"file.ml" ~before:(text_image original)
        ~after:(text_image modified) 0;
    ]
  in
  let fs = [ ("file.ml", drifted) ] in
  let plan = M.Revert.plan ~read:(read_of fs) ~scope:M.Scope.Session changes in
  equal int ~msg:"no ready paths" 0 (List.length plan.M.Revert.ready);
  (match plan.M.Revert.problems with
  | [ M.Revert.Stale stale ] ->
      equal image ~msg:"expected image" (text_image modified)
        stale.M.Revert.expected;
      equal image ~msg:"actual image" (text_image drifted) stale.M.Revert.actual
  | _ -> failf "expected one stale problem");
  match M.Revert.lower plan ~resolve ~blob:(blob_of [ original ]) with
  | Ok _ -> failf "lowering a stale plan must fail"
  | Error problems -> equal int ~msg:"stale propagates" 1 (List.length problems)

let revert_blob_failures () =
  let original = "original\n" in
  let modified = "modified\n" in
  let changes =
    [
      change ~path:"file.ml" ~before:(text_image original)
        ~after:(text_image modified) 0;
    ]
  in
  let fs = [ ("file.ml", modified) ] in
  let plan = M.Revert.plan ~read:(read_of fs) ~scope:M.Scope.Session changes in
  (match M.Revert.lower plan ~resolve ~blob:(fun _ -> None) with
  | Ok _ -> failf "missing blob must refuse"
  | Error [ M.Revert.Refused refusal ] ->
      equal string ~msg:"missing blob reason" "evidence blob missing"
        refusal.M.Revert.reason
  | Error _ -> failf "expected one refusal for missing blob");
  match M.Revert.lower plan ~resolve ~blob:(fun _ -> Some "corrupt\n") with
  | Ok _ -> failf "corrupt blob must refuse"
  | Error [ M.Revert.Refused refusal ] ->
      equal string ~msg:"corrupt blob reason" "evidence blob corrupt"
        refusal.M.Revert.reason
  | Error _ -> failf "expected one refusal for corrupt blob"

let revert_of_revert_is_empty () =
  let original = "original\n" in
  let modified = "modified\n" in
  let forward =
    change ~path:"file.ml" ~before:(text_image original)
      ~after:(text_image modified) 0
  in
  let revert_row =
    M.Change.make
      ~id:(M.Change.Id.of_string "change:revert-row")
      ~session ~turn
      ~source:
        (M.Change.Revert
           (M.Revert.derive_id ~session ~scope:M.Scope.Session ~ordinal:0))
      ~path:(rel "file.ml") ~op:M.Change.Modify ~before:(text_image modified)
      ~after:(text_image original) ~additions:1 ~deletions:1
      ~revertability:M.Change.Revertable ()
  in
  equal int ~msg:"forward plus revert nets to nothing" 0
    (List.length (M.Change.net [ forward; revert_row ]))

let deterministic_ids () =
  let id index = M.Change.derive_id ~execution ~path:(rel "file.ml") ~index in
  is_true ~msg:"same inputs derive the same id"
    (M.Change.Id.equal (id 0) (id 0));
  is_true ~msg:"distinct indexes derive distinct ids"
    (not (M.Change.Id.equal (id 0) (id 1)));
  is_true ~msg:"checkpoint ids are deterministic"
    (M.Checkpoint.Id.equal
       (M.Checkpoint.derive_id ~session ~turn ~reason:M.Checkpoint.Run_end)
       (M.Checkpoint.derive_id ~session ~turn ~reason:M.Checkpoint.Run_end))

let codec_roundtrips () =
  let a = text_image "a\n" in
  List.iter
    (fun value ->
      equal image ~msg:"image roundtrip" value
        (roundtrip "image" M.Image.jsont value))
    [ M.Image.Missing; a; M.Image.Unsupported { reason = "binary" } ];
  List.iter
    (fun value ->
      equal scope ~msg:"scope roundtrip" value
        (roundtrip "scope" M.Scope.jsont value))
    [
      M.Scope.Session;
      M.Scope.Turn turn;
      M.Scope.Turns [ turn; other_turn ];
      M.Scope.Turns [];
      M.Scope.Change (M.Change.Id.of_string "change:x");
      M.Scope.Path (rel "a/b.ml");
    ];
  let checkpoint =
    M.Checkpoint.make
      ~id:(M.Checkpoint.derive_id ~session ~turn ~reason:M.Checkpoint.Manual)
      ~session ~turn ~root:"/workspace" ~reason:M.Checkpoint.Manual
      ~status:
        (M.Checkpoint.Available
           { backend = "git_tree"; reference = "abc123"; excluded = 2 })
  in
  let change_row =
    change ~path:"moved.ml"
      ~op:(M.Change.Move { from = rel "old.ml" })
      ~before:a ~after:a 0
  in
  let revert =
    M.Revert.make
      ~id:(M.Revert.derive_id ~session ~scope:(M.Scope.Turn turn) ~ordinal:0)
      ~session ~scope:(M.Scope.Turn turn)
      ~pre_revert:(M.Checkpoint.id checkpoint)
      ~applied:
        [
          {
            M.Revert.applied_path = rel "moved.ml";
            applied_sources = [ M.Change.id change_row ];
          };
        ]
      ()
  in
  List.iter
    (fun value ->
      equal record ~msg:"record roundtrip" value
        (roundtrip "record" M.Record.jsont value))
    [
      M.Record.Checkpoint checkpoint;
      M.Record.Change change_row;
      M.Record.Revert revert;
    ];
  equal int ~msg:"changes projection" 1
    (List.length
       (M.changes
          [ M.Record.Checkpoint checkpoint; M.Record.Change change_row ]));
  equal int ~msg:"checkpoints projection" 1
    (List.length
       (M.checkpoints
          [ M.Record.Checkpoint checkpoint; M.Record.Change change_row ]))

(* The persisted per-path revert result was narrowed to applied-only, but the
   [case_mem "kind"] tagged-union wire shape must be retained so on-disk ledgers
   written by earlier versions still decode. A value round-trip cannot catch a
   regression to a bare object (encode and decode would change together and stay
   mutually consistent); pin the concrete wire bytes instead. *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    i + nl <= hl
    && (String.equal (String.sub haystack i nl) needle || go (i + 1))
  in
  go 0

let compact json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> String.concat "" (String.split_on_char ' ' text)
  | Error error -> failf "encode failed: %s" error

let revert_wire_is_kind_tagged () =
  let change_row =
    change ~path:"moved.ml"
      ~op:(M.Change.Move { from = rel "old.ml" })
      ~before:(text_image "a\n") ~after:(text_image "a\n") 0
  in
  let revert =
    M.Revert.make
      ~id:(M.Revert.derive_id ~session ~scope:(M.Scope.Turn turn) ~ordinal:0)
      ~session ~scope:(M.Scope.Turn turn)
      ~applied:
        [
          {
            M.Revert.applied_path = rel "moved.ml";
            applied_sources = [ M.Change.id change_row ];
          };
        ]
      ()
  in
  let record = M.Record.Revert revert in
  let json =
    match Jsont.Json.encode M.Record.jsont record with
    | Ok json -> json
    | Error error -> failf "record encode failed: %s" error
  in
  let wire = compact json in
  is_true ~msg:"outer record stays type-tagged"
    (contains ~needle:{|"type":"revert"|} wire);
  is_true ~msg:"per-path result keeps its kind discriminator (no bare object)"
    (contains ~needle:{|"kind":"applied"|} wire);
  (* A byte-identical on-disk line (this is exactly the legacy shape) still
     decodes to the same record. *)
  match Jsont_bytesrw.decode_string M.Record.jsont (compact json) with
  | Ok decoded ->
      equal
        (testable ~pp:M.Record.pp ~equal:M.Record.equal ())
        ~msg:"wire decodes" record decoded
  | Error error -> failf "record decode failed: %s" error

let checkpoint ~reason ~status =
  M.Checkpoint.make
    ~id:(M.Checkpoint.derive_id ~session ~turn ~reason)
    ~session ~turn ~root:"/workspace" ~reason ~status

let available_checkpoint reason =
  checkpoint ~reason
    ~status:
      (M.Checkpoint.Available
         { backend = "git_tree"; reference = "ref"; excluded = 0 })

let degraded_checkpoint reason =
  checkpoint ~reason
    ~status:(M.Checkpoint.Degraded { backend = "git_tree"; message = "boom" })

let find_checkpoint_locates_by_id () =
  let manual = available_checkpoint M.Checkpoint.Manual in
  let before = degraded_checkpoint M.Checkpoint.Before_mutation in
  let change_row =
    change ~path:"a.ml" ~before:M.Image.Missing ~after:(text_image "a\n") 0
  in
  let records =
    [
      M.Record.Checkpoint manual;
      M.Record.Change change_row;
      M.Record.Checkpoint before;
    ]
  in
  (match M.find_checkpoint records (M.Checkpoint.id before) with
  | Some found ->
      is_true ~msg:"find_checkpoint returns the matching checkpoint"
        (M.Checkpoint.equal found before)
  | None -> failf "find_checkpoint should locate the checkpoint by id");
  let absent =
    M.Checkpoint.derive_id ~session ~turn:other_turn ~reason:M.Checkpoint.Manual
  in
  is_true ~msg:"an unknown id finds nothing"
    (Option.is_none (M.find_checkpoint records absent))

let available_id_gates_on_status () =
  let ok = available_checkpoint M.Checkpoint.Manual in
  let bad = degraded_checkpoint M.Checkpoint.Before_mutation in
  (match M.Checkpoint.available_id ok with
  | Some id ->
      is_true ~msg:"an available checkpoint yields its id"
        (M.Checkpoint.Id.equal id (M.Checkpoint.id ok))
  | None -> failf "an available checkpoint should yield an id");
  is_true ~msg:"a degraded checkpoint yields no id"
    (Option.is_none (M.Checkpoint.available_id bad))

let () =
  run "spice.mutation"
    [
      test "net folds endpoints" net_endpoints;
      test "net drops no-ops" net_drops_noops;
      test "net flags discontinuous chains" net_contiguity_flag;
      test "net expands moves" net_move_expansion;
      test "net handles create-then-move" net_create_then_move;
      test "net handles move chains" net_move_chain;
      test "scope selection" scope_selection;
      test "change totals" change_totals;
      test "revert plans and lowers" revert_plan_and_lower;
      test "revert refuses stale paths" revert_stale_refusal;
      test "revert refuses missing or corrupt blobs" revert_blob_failures;
      test "revert of a revert nets to nothing" revert_of_revert_is_empty;
      test "deterministic ids" deterministic_ids;
      test "find_checkpoint locates by id" find_checkpoint_locates_by_id;
      test "available_id gates on status" available_id_gates_on_status;
      test "codec roundtrips" codec_roundtrips;
      test "revert wire stays kind-tagged" revert_wire_is_kind_tagged;
    ]
