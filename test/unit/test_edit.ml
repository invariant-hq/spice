(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Edit = Spice_edit
module W = Spice_workspace
module Path = Spice_path

let edit_error = testable ~pp:Edit.Error.pp ~equal:Edit.Error.equal ()
let target_value = testable ~pp:Edit.Observed.pp ~equal:Edit.Observed.equal ()

let kind_value =
  let pp ppf = function
    | `Create -> Format.pp_print_string ppf "create"
    | `Modify -> Format.pp_print_string ppf "modify"
    | `Delete -> Format.pp_print_string ppf "delete"
  in
  testable ~pp ~equal:(fun (a : Edit.kind) b -> a = b) ()

let identity_value =
  testable ~pp:Spice_digest.Identity.pp ~equal:Spice_digest.Identity.equal ()

let result_entry =
  testable ~pp:Edit.Result.Entry.pp ~equal:Edit.Result.Entry.equal ()

let expect_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %a" label Edit.Error.pp error

let expect_apply_ok label = function
  | Ok value -> value
  | Error error -> failf "%s: %a" label Edit.Apply_error.pp error

let expect_apply_error label result =
  match result with
  | Ok _ -> failf "%s: expected apply error" label
  | Error error -> error

let abs text =
  match Path.Abs.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Path.Error.pp error

let rel text =
  match Path.Rel.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Path.Error.pp error

let root = W.Root.make (abs "/workspace")
let workspace = W.single root
let path text = W.Path.make ~root (rel text)
let display path = W.Path.display path
let path_value = testable ~pp:W.Path.pp ~equal:W.Path.equal ()
let missing = Edit.Observed.Missing
let text contents = Edit.Observed.Text contents

type event =
  | Lock of W.Path.t list
  | Revalidate of W.Path.t
  | Read of W.Path.t
  | Write of W.Path.t * string
  | Remove of W.Path.t

let equal_event a b =
  match (a, b) with
  | Lock a, Lock b -> List.equal W.Path.equal a b
  | Revalidate a, Revalidate b | Read a, Read b | Remove a, Remove b ->
      W.Path.equal a b
  | Write (a_path, a_contents), Write (b_path, b_contents) ->
      W.Path.equal a_path b_path && String.equal a_contents b_contents
  | (Lock _ | Revalidate _ | Read _ | Write _ | Remove _), _ -> false

let pp_path ppf path = Format.pp_print_string ppf (display path)

let pp_event ppf = function
  | Lock paths ->
      Format.fprintf ppf "lock:[%a]"
        (Format.pp_print_list
           ~pp_sep:(fun ppf () -> Format.pp_print_string ppf ",")
           pp_path)
        paths
  | Revalidate path -> Format.fprintf ppf "revalidate:%a" pp_path path
  | Read path -> Format.fprintf ppf "read:%a" pp_path path
  | Write (path, contents) ->
      Format.fprintf ppf "write:%a:%S" pp_path path contents
  | Remove path -> Format.fprintf ppf "remove:%a" pp_path path

let event = testable ~pp:pp_event ~equal:equal_event ()

type fake = {
  io : Edit.Apply.io;
  targets : (W.Path.t * Edit.Observed.t) list ref;
  events : event list ref;
  revalidate : W.Path.t -> (W.Path.t, Edit.Error.t) result;
  mutable lock_error : Edit.Error.t option;
  mutable read_error : (W.Path.t * Edit.Error.t) option;
  mutable fail_write : W.Path.t option;
  mutable fail_remove : W.Path.t option;
}

let target_of fake path =
  match
    List.find_opt
      (fun (candidate, _) -> W.Path.equal path candidate)
      !(fake.targets)
  with
  | None -> Edit.Observed.Missing
  | Some (_, target) -> target

let set_target fake path target =
  fake.targets :=
    (path, target)
    :: List.filter
         (fun (candidate, _) -> not (W.Path.equal path candidate))
         !(fake.targets)

let note fake event = fake.events := !(fake.events) @ [ event ]

let make_io ?(targets = []) ?(revalidate = fun path -> Ok path) () =
  let holder = ref None in
  let with_fake f =
    match !holder with Some fake -> f fake | None -> failf "missing fake IO"
  in
  let with_write_lock paths f =
    with_fake @@ fun fake ->
    note fake (Lock paths);
    match fake.lock_error with Some error -> Error error | None -> f ()
  in
  let revalidate_path path =
    with_fake @@ fun fake ->
    note fake (Revalidate path);
    fake.revalidate path
  in
  let read path =
    with_fake @@ fun fake ->
    note fake (Read path);
    match fake.read_error with
    | Some (failed, error) when W.Path.equal failed path -> Error error
    | Some _ | None -> Ok (target_of fake path)
  in
  let write path contents =
    with_fake @@ fun fake ->
    note fake (Write (path, contents));
    match fake.fail_write with
    | Some failed when W.Path.equal failed path ->
        Error (Edit.Error.io ~path "write failed")
    | Some _ | None ->
        set_target fake path (Edit.Observed.Text contents);
        Ok ()
  in
  let remove path =
    with_fake @@ fun fake ->
    note fake (Remove path);
    match fake.fail_remove with
    | Some failed when W.Path.equal failed path ->
        Error (Edit.Error.io ~path "remove failed")
    | Some _ | None ->
        set_target fake path Edit.Observed.Missing;
        Ok ()
  in
  let commit ~path ~before ~after =
    match (before, after) with
    | _, Edit.State.Text contents -> write path contents
    | Edit.State.Text _, Edit.State.Missing
    | Edit.State.Missing, Edit.State.Missing ->
        remove path
  in
  let io =
    { Edit.Apply.with_write_lock; revalidate = revalidate_path; read; commit }
  in
  let fake =
    {
      io;
      targets = ref targets;
      events = ref [];
      revalidate;
      lock_error = None;
      read_error = None;
      fail_write = None;
      fail_remove = None;
    }
  in
  holder := Some fake;
  fake

let events fake = !(fake.events)
let current fake path = target_of fake path
let mutating_event = function Write _ | Remove _ -> true | _ -> false
let create path contents = expect_ok "create" (Edit.create ~path ~contents)

let rewrite path before after =
  expect_ok "rewrite" (Edit.rewrite ~path ~before ~after)

let delete path before = expect_ok "delete" (Edit.delete ~path ~before)
let concat plans = expect_ok "concat" (Edit.concat plans)

let apply_plan ?(targets = []) plan =
  let fake = make_io ~targets () in
  expect_apply_ok "apply" (Edit.apply ~io:fake.io ~workspace plan)

let change_constructors_and_plan_algebra () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let c = path "c.txt" in
  let create = create a "new\n" in
  let rewrite_plan = rewrite b "old\n" "next\n" in
  let delete = delete c "gone\n" in
  let noop = rewrite b "same\n" "same\n" in
  is_true ~msg:"no-op rewrite is empty" (Edit.is_empty noop);
  let plan = concat [ Edit.empty; create; noop; rewrite_plan; delete ] in
  let result =
    apply_plan ~targets:[ (b, text "old\n"); (c, text "gone\n") ] plan
  in
  match Edit.Result.entries result with
  | [ create_entry; rewrite_entry; delete_entry ] ->
      equal path_value ~msg:"create path" a
        (Edit.Result.Entry.target_path create_entry);
      equal target_value ~msg:"create before" missing
        (Edit.Result.Entry.before create_entry);
      equal target_value ~msg:"create after" (text "new\n")
        (Edit.Result.Entry.after create_entry);
      equal path_value ~msg:"rewrite path" b
        (Edit.Result.Entry.target_path rewrite_entry);
      equal target_value ~msg:"rewrite before" (text "old\n")
        (Edit.Result.Entry.before rewrite_entry);
      equal target_value ~msg:"rewrite after" (text "next\n")
        (Edit.Result.Entry.after rewrite_entry);
      equal path_value ~msg:"delete path" c
        (Edit.Result.Entry.target_path delete_entry);
      equal target_value ~msg:"delete before" (text "gone\n")
        (Edit.Result.Entry.before delete_entry);
      equal target_value ~msg:"delete after" missing
        (Edit.Result.Entry.after delete_entry)
  | entries -> failf "unexpected entries: %d" (List.length entries)

let change_observers () =
  let created = path "created.txt" in
  let rewritten = path "rewritten.txt" in
  let deleted = path "deleted.txt" in
  let plan =
    concat
      [
        create created "new\n";
        rewrite rewritten "old\n" "new\n";
        delete deleted "gone\n";
      ]
  in
  let result =
    apply_plan
      ~targets:[ (rewritten, text "old\n"); (deleted, text "gone\n") ]
      plan
  in
  let entries = Edit.Result.entries result in
  equal (list path_value) ~msg:"entry paths"
    [ created; rewritten; deleted ]
    (List.map Edit.Result.Entry.target_path entries);
  equal (list kind_value) ~msg:"entry kinds"
    [ `Create; `Modify; `Delete ]
    (List.map Edit.Result.Entry.kind entries);
  equal (list target_value) ~msg:"entry before values"
    [ missing; text "old\n"; text "gone\n" ]
    (List.map Edit.Result.Entry.before entries);
  equal (list target_value) ~msg:"entry after values"
    [ text "new\n"; text "new\n"; missing ]
    (List.map Edit.Result.Entry.after entries)

let invalid_text_is_rejected () =
  let file = path "bad.txt" in
  equal
    (result (testable ~pp:Edit.pp ~equal:Edit.equal ()) edit_error)
    ~msg:"create rejects invalid text"
    (Error (Edit.Error.invalid_text ~path:file "invalid UTF-8"))
    (Edit.create ~path:file ~contents:"\255");
  equal
    (result (testable ~pp:Edit.pp ~equal:Edit.equal ()) edit_error)
    ~msg:"rewrite rejects invalid before"
    (Error (Edit.Error.invalid_text ~path:file "invalid UTF-8"))
    (Edit.rewrite ~path:file ~before:"\255" ~after:"ok");
  equal
    (result (testable ~pp:Edit.pp ~equal:Edit.equal ()) edit_error)
    ~msg:"rewrite rejects invalid after"
    (Error (Edit.Error.invalid_text ~path:file "invalid UTF-8"))
    (Edit.rewrite ~path:file ~before:"ok" ~after:"\255");
  equal
    (result (testable ~pp:Edit.pp ~equal:Edit.equal ()) edit_error)
    ~msg:"delete rejects invalid before"
    (Error (Edit.Error.invalid_text ~path:file "invalid UTF-8"))
    (Edit.delete ~path:file ~before:"\255")

let concat_rejects_duplicate_planned_paths () =
  let file = path "same.txt" in
  let a = create file "a" in
  let b = delete file "b" in
  equal
    (testable ~pp:Edit.pp ~equal:Edit.equal ())
    ~msg:"empty plans are ignored" a
    (concat [ Edit.empty; a; Edit.empty ]);
  equal
    (result (testable ~pp:Edit.pp ~equal:Edit.equal ()) edit_error)
    ~msg:"duplicate planned path"
    (Error (Edit.Error.duplicate_path file))
    (Edit.concat [ Edit.empty; a; Edit.empty; b ])

let error_constructors_reject_empty_messages () =
  expect_invalid_arg "invalid_text rejects empty reason" (fun () ->
      Edit.Error.invalid_text "" |> ignore);
  expect_invalid_arg "io rejects empty reason" (fun () ->
      Edit.Error.io "" |> ignore)

let diff_renders_all_changes () =
  let created = path "created.txt" in
  let rewritten = path "rewritten.txt" in
  let plan =
    concat
      [
        create created "new\n";
        rewrite rewritten "old\n" "new\n";
        delete (path "deleted.txt") "gone\n";
      ]
  in
  let diff = Edit.diff plan in
  let stats = Spice_diff.stats diff in
  equal int ~msg:"changed files" 3 stats.Spice_diff.files;
  equal int ~msg:"additions" 2 stats.Spice_diff.additions;
  equal int ~msg:"deletions" 2 stats.Spice_diff.deletions

let default_diff_escapes_header_path () =
  let file = path "bad\nname.txt" in
  let rendered = Edit.diff (rewrite file "old\n" "new\n") in
  match String.split_on_char '\n' (Spice_diff.to_string rendered) with
  | before_header :: after_header :: _ ->
      is_true ~msg:"before header escapes newline"
        (String.ends_with ~suffix:"bad\\nname.txt" before_header);
      is_true ~msg:"after header escapes newline"
        (String.ends_with ~suffix:"bad\\nname.txt" after_header)
  | _ -> failf "expected unified diff headers"

let apply_empty_is_noop () =
  let fake =
    make_io ~targets:[ (path "a.txt", Edit.Observed.Text "old\n") ] ()
  in
  let result =
    expect_apply_ok "apply empty" (Edit.apply ~io:fake.io ~workspace Edit.empty)
  in
  equal int ~msg:"empty result entries" 0
    (List.length (Edit.Result.entries result));
  equal (list event) ~msg:"no IO events" [] (events fake)

let lock_failure_blocks_all_work () =
  let file = path "new.txt" in
  let fake = make_io () in
  let lock_error = Edit.Error.io "lock failed" in
  fake.lock_error <- Some lock_error;
  let error =
    expect_apply_error "lock failure"
      (Edit.apply ~io:fake.io ~workspace (create file "x"))
  in
  equal edit_error ~msg:"lock error" lock_error (Edit.Apply_error.error error);
  equal (list result_entry) ~msg:"nothing applied" []
    (Edit.Apply_error.applied error);
  equal (list event) ~msg:"no work inside failed lock" [ Lock [ file ] ]
    (events fake)

let apply_success_validates_then_mutates_in_order () =
  let c = path "c.txt" in
  let a = path "a.txt" in
  let b = path "b.txt" in
  let plan =
    concat
      [ create c "created\n"; rewrite a "old\n" "new\n"; delete b "gone\n" ]
  in
  let fake =
    make_io
      ~targets:
        [ (a, Edit.Observed.Text "old\n"); (b, Edit.Observed.Text "gone\n") ]
      ()
  in
  let result =
    expect_apply_ok "apply" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal target_value ~msg:"created target" (text "created\n") (current fake c);
  equal target_value ~msg:"rewritten target" (text "new\n") (current fake a);
  equal target_value ~msg:"deleted target" missing (current fake b);
  equal (list event) ~msg:"operation order"
    [
      Lock [ c; a; b ];
      Revalidate c;
      Revalidate a;
      Revalidate b;
      Read c;
      Read a;
      Read b;
      Write (c, "created\n");
      Write (a, "new\n");
      Remove b;
    ]
    (events fake);
  match Edit.Result.entries result with
  | [ created; rewritten; deleted ] ->
      equal path_value ~msg:"created target path" c
        (Edit.Result.Entry.target_path created);
      equal target_value ~msg:"created before" missing
        (Edit.Result.Entry.before created);
      equal target_value ~msg:"created after" (text "created\n")
        (Edit.Result.Entry.after created);
      equal path_value ~msg:"rewritten target path" a
        (Edit.Result.Entry.target_path rewritten);
      equal target_value ~msg:"rewrite before" (text "old\n")
        (Edit.Result.Entry.before rewritten);
      equal target_value ~msg:"rewrite after" (text "new\n")
        (Edit.Result.Entry.after rewritten);
      equal path_value ~msg:"deleted target path" b
        (Edit.Result.Entry.target_path deleted);
      equal target_value ~msg:"delete before" (text "gone\n")
        (Edit.Result.Entry.before deleted);
      equal target_value ~msg:"delete after" missing
        (Edit.Result.Entry.after deleted)
  | entries -> failf "expected three entries, got %d" (List.length entries)

let apply_records_revalidated_target_path () =
  let requested = path "requested.txt" in
  let canonical = path "canonical.txt" in
  let plan = create requested "created\n" in
  let fake =
    make_io
      ~revalidate:(fun path ->
        if W.Path.equal path requested then Ok canonical else Ok path)
      ()
  in
  let result =
    expect_apply_ok "apply" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal target_value ~msg:"canonical target written" (text "created\n")
    (current fake canonical);
  match Edit.Result.entries result with
  | [ entry ] ->
      equal path_value ~msg:"target path is revalidated" canonical
        (Edit.Result.Entry.target_path entry)
  | entries -> failf "expected one entry, got %d" (List.length entries)

let apply_records_revalidated_rewrite_target_path () =
  let requested = path "requested.txt" in
  let canonical = path "canonical.txt" in
  let plan = rewrite requested "old\n" "new\n" in
  let fake =
    make_io
      ~targets:[ (canonical, text "old\n") ]
      ~revalidate:(fun path ->
        if W.Path.equal path requested then Ok canonical else Ok path)
      ()
  in
  let result =
    expect_apply_ok "apply rewrite" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal target_value ~msg:"canonical target rewritten" (text "new\n")
    (current fake canonical);
  match Edit.Result.entries result with
  | [ entry ] ->
      equal path_value ~msg:"target path is revalidated" canonical
        (Edit.Result.Entry.target_path entry);
      equal target_value ~msg:"before from canonical target" (text "old\n")
        (Edit.Result.Entry.before entry);
      equal target_value ~msg:"after from planned edit" (text "new\n")
        (Edit.Result.Entry.after entry)
  | entries -> failf "expected one entry, got %d" (List.length entries)

let accessors_expose_apply_evidence () =
  let file = path "a.txt" in
  let canonical = path "canonical.txt" in
  equal (option string) ~msg:"observed text" (Some "old\n")
    (Edit.Observed.text (text "old\n"));
  equal (option string) ~msg:"missing text" None
    (Edit.Observed.text Edit.Observed.Missing);
  equal (option identity_value) ~msg:"observed identity"
    (Some (Spice_digest.Identity.of_contents "old\n"))
    (Edit.Observed.identity (text "old\n"));
  equal bool ~msg:"empty result is empty" true
    (Edit.Result.is_empty Edit.Result.empty);
  let fake =
    make_io
      ~targets:[ (canonical, text "old\n") ]
      ~revalidate:(fun path ->
        if W.Path.equal path file then Ok canonical else Ok path)
      ()
  in
  let result =
    expect_apply_ok "apply accessor evidence"
      (Edit.apply ~io:fake.io ~workspace (rewrite file "old\n" "new\n"))
  in
  equal bool ~msg:"non-empty result is not empty" false
    (Edit.Result.is_empty result);
  match Edit.Result.entries result with
  | [ entry ] ->
      equal path_value ~msg:"entry target path" canonical
        (Edit.Result.Entry.target_path entry);
      equal target_value ~msg:"entry before" (text "old\n")
        (Edit.Result.Entry.before entry);
      equal target_value ~msg:"entry after" (text "new\n")
        (Edit.Result.Entry.after entry);
      equal kind_value ~msg:"entry kind" `Modify (Edit.Result.Entry.kind entry)
  | entries -> failf "expected one entry, got %d" (List.length entries)

let duplicate_revalidated_path_blocks_reads_and_writes () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let plan = concat [ create a "a"; create b "b" ] in
  let fake =
    make_io
      ~revalidate:(fun path -> if W.Path.equal path b then Ok a else Ok path)
      ()
  in
  let error =
    expect_apply_error "duplicate revalidated path"
      (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal edit_error ~msg:"duplicate path error"
    (Edit.Error.duplicate_path a)
    (Edit.Apply_error.error error);
  equal (list result_entry) ~msg:"no applied entries" []
    (Edit.Apply_error.applied error);
  equal (list event) ~msg:"no reads or writes after duplicate"
    [ Lock [ a; b ]; Revalidate a; Revalidate b ]
    (events fake)

let state_mismatches_fail_before_mutation () =
  let create_path = path "existing.txt" in
  let delete_path = path "missing.txt" in
  let other_path = path "dir" in
  let cases =
    [
      ( "create existing",
        create create_path "new",
        [ (create_path, Edit.Observed.Text "old") ],
        Edit.Error.state_mismatch ~path:create_path ~expected:`Missing
          ~actual:`Text );
      ( "delete missing",
        delete delete_path "old",
        [],
        Edit.Error.state_mismatch ~path:delete_path ~expected:`Text
          ~actual:`Missing );
      ( "rewrite other",
        rewrite other_path "old" "new",
        [ (other_path, Edit.Observed.Other) ],
        Edit.Error.state_mismatch ~path:other_path ~expected:`Text
          ~actual:`Other );
    ]
  in
  List.iter
    (fun (label, plan, targets, expected) ->
      let fake = make_io ~targets () in
      let error =
        expect_apply_error label (Edit.apply ~io:fake.io ~workspace plan)
      in
      equal edit_error ~msg:(label ^ " error") expected
        (Edit.Apply_error.error error);
      is_true ~msg:(label ^ " has no writes")
        (not (List.exists mutating_event (events fake))))
    cases

let stale_write_blocks_all_mutation () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let plan =
    concat [ rewrite a "old a\n" "new a\n"; rewrite b "old b\n" "new b\n" ]
  in
  let fake =
    make_io
      ~targets:
        [ (a, Edit.Observed.Text "old a\n"); (b, text "changed elsewhere\n") ]
      ()
  in
  let error =
    expect_apply_error "stale" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal edit_error ~msg:"stale error"
    (Edit.Error.conflict ~path:b ~expected:(Edit.State.Text "old b\n")
       ~actual:(text "changed elsewhere\n"))
    (Edit.Apply_error.error error);
  equal target_value ~msg:"a unchanged" (text "old a\n") (current fake a);
  equal target_value ~msg:"b unchanged"
    (text "changed elsewhere\n")
    (current fake b);
  is_true ~msg:"no writes or removes"
    (not (List.exists mutating_event (events fake)))

let revalidation_failure_blocks_reads_and_writes () =
  let file = path "new.txt" in
  let blocked =
    Edit.Error.workspace ~path:file
      (W.Resolve_error.Outside_workspace (W.Path.abs file))
  in
  let fake = make_io ~revalidate:(fun _ -> Error blocked) () in
  let error =
    expect_apply_error "revalidate"
      (Edit.apply ~io:fake.io ~workspace (create file "x"))
  in
  equal edit_error ~msg:"revalidation error" blocked
    (Edit.Apply_error.error error);
  equal (list event) ~msg:"only lock and revalidate"
    [ Lock [ file ]; Revalidate file ]
    (events fake)

let revalidation_outside_workspace_blocks_reads_and_writes () =
  let file = path "new.txt" in
  let outside_root = W.Root.make (abs "/outside") in
  let outside = W.Path.make ~root:outside_root (rel "new.txt") in
  let fake = make_io ~revalidate:(fun _ -> Ok outside) () in
  let error =
    expect_apply_error "outside workspace"
      (Edit.apply ~io:fake.io ~workspace (create file "x"))
  in
  equal edit_error ~msg:"workspace confinement error"
    (Edit.Error.out_of_workspace outside)
    (Edit.Apply_error.error error);
  equal (list event) ~msg:"only lock and revalidate"
    [ Lock [ file ]; Revalidate file ]
    (events fake)

let read_error_blocks_mutation () =
  let file = path "a.txt" in
  let fake = make_io () in
  let read_error = Edit.Error.too_large ~path:file ~size:10L ~max_size:5L in
  fake.read_error <- Some (file, read_error);
  let error =
    expect_apply_error "read error"
      (Edit.apply ~io:fake.io ~workspace (delete file "old"))
  in
  equal edit_error ~msg:"read error" read_error (Edit.Apply_error.error error);
  equal (list result_entry) ~msg:"nothing applied" []
    (Edit.Apply_error.applied error);
  is_true ~msg:"no writes or removes"
    (not (List.exists mutating_event (events fake)))

let later_read_error_blocks_all_mutation () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let c = path "c.txt" in
  let plan =
    concat
      [ rewrite a "a\n" "A\n"; rewrite b "b\n" "B\n"; rewrite c "c\n" "C\n" ]
  in
  let fake =
    make_io ~targets:[ (a, text "a\n"); (b, text "b\n"); (c, text "c\n") ] ()
  in
  let read_error = Edit.Error.io ~path:c "read failed" in
  fake.read_error <- Some (c, read_error);
  let error =
    expect_apply_error "later read error"
      (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal edit_error ~msg:"read error" read_error (Edit.Apply_error.error error);
  equal (list result_entry) ~msg:"nothing applied" []
    (Edit.Apply_error.applied error);
  equal (list event) ~msg:"all reads happen before mutations"
    [
      Lock [ a; b; c ];
      Revalidate a;
      Revalidate b;
      Revalidate c;
      Read a;
      Read b;
      Read c;
    ]
    (events fake);
  equal target_value ~msg:"a unchanged" (text "a\n") (current fake a);
  equal target_value ~msg:"b unchanged" (text "b\n") (current fake b);
  equal target_value ~msg:"c unchanged" (text "c\n") (current fake c)

let later_write_failure_reports_confirmed_entries () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let c = path "c.txt" in
  let plan =
    concat
      [ rewrite a "a\n" "A\n"; rewrite b "b\n" "B\n"; rewrite c "c\n" "C\n" ]
  in
  let fake =
    make_io ~targets:[ (a, text "a\n"); (b, text "b\n"); (c, text "c\n") ] ()
  in
  fake.fail_write <- Some b;
  let error =
    expect_apply_error "partial write" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal edit_error ~msg:"write failure"
    (Edit.Error.io ~path:b "write failed")
    (Edit.Apply_error.error error);
  equal target_value ~msg:"a was written" (text "A\n") (current fake a);
  equal target_value ~msg:"b unchanged" (text "b\n") (current fake b);
  equal target_value ~msg:"c unchanged" (text "c\n") (current fake c);
  match Edit.Apply_error.applied error with
  | [ entry ] ->
      equal path_value ~msg:"applied target path" a
        (Edit.Result.Entry.target_path entry);
      equal target_value ~msg:"applied before" (text "a\n")
        (Edit.Result.Entry.before entry);
      equal target_value ~msg:"applied after" (text "A\n")
        (Edit.Result.Entry.after entry)
  | entries -> failf "expected one applied entry, got %d" (List.length entries)

let later_remove_failure_reports_confirmed_entries () =
  let a = path "a.txt" in
  let b = path "b.txt" in
  let plan = concat [ rewrite a "a\n" "A\n"; delete b "b\n" ] in
  let fake = make_io ~targets:[ (a, text "a\n"); (b, text "b\n") ] () in
  fake.fail_remove <- Some b;
  let error =
    expect_apply_error "partial remove" (Edit.apply ~io:fake.io ~workspace plan)
  in
  equal edit_error ~msg:"remove failure"
    (Edit.Error.io ~path:b "remove failed")
    (Edit.Apply_error.error error);
  equal target_value ~msg:"a was written" (text "A\n") (current fake a);
  equal target_value ~msg:"b remains" (text "b\n") (current fake b);
  match Edit.Apply_error.applied error with
  | [ entry ] ->
      equal path_value ~msg:"applied target path" a
        (Edit.Result.Entry.target_path entry);
      equal target_value ~msg:"applied before" (text "a\n")
        (Edit.Result.Entry.before entry);
      equal target_value ~msg:"applied after" (text "A\n")
        (Edit.Result.Entry.after entry)
  | entries -> failf "expected one applied entry, got %d" (List.length entries)

let () =
  run "spice.edit"
    [
      test "applies constructed plans in order"
        change_constructors_and_plan_algebra;
      test "apply entries expose change facts" change_observers;
      test "rejects invalid UTF-8 text" invalid_text_is_rejected;
      test "error constructors reject empty messages"
        error_constructors_reject_empty_messages;
      test "concat rejects duplicate planned paths"
        concat_rejects_duplicate_planned_paths;
      test "diff renders all changes" diff_renders_all_changes;
      test "default diff escapes header paths" default_diff_escapes_header_path;
      test "apply empty is a no-op" apply_empty_is_noop;
      test "lock failure blocks all work" lock_failure_blocks_all_work;
      test "apply succeeds in validated order"
        apply_success_validates_then_mutates_in_order;
      test "apply records revalidated target path"
        apply_records_revalidated_target_path;
      test "apply records revalidated rewrite target path"
        apply_records_revalidated_rewrite_target_path;
      test "accessors expose apply evidence" accessors_expose_apply_evidence;
      test "duplicate revalidated path blocks mutation"
        duplicate_revalidated_path_blocks_reads_and_writes;
      test "state mismatches fail before mutation"
        state_mismatches_fail_before_mutation;
      test "stale write blocks all mutation" stale_write_blocks_all_mutation;
      test "revalidation failure blocks reads and writes"
        revalidation_failure_blocks_reads_and_writes;
      test "revalidation outside workspace blocks reads and writes"
        revalidation_outside_workspace_blocks_reads_and_writes;
      test "read error blocks mutation" read_error_blocks_mutation;
      test "later read error blocks all mutation"
        later_read_error_blocks_all_mutation;
      test "later write failure reports confirmed entries"
        later_write_failure_reports_confirmed_entries;
      test "later remove failure reports confirmed entries"
        later_remove_failure_reports_confirmed_entries;
    ]
