(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Review = Spice_review
module Git = Spice_review_git

let expect_ok msg = function
  | Ok value -> value
  | Error error -> failf "%s: %a" msg Git.Error.pp error

let write dir path contents =
  let abs = Filename.concat dir path in
  let parent = Filename.dirname abs in
  if not (Sys.file_exists parent) then Unix.mkdir parent 0o755;
  Out_channel.with_open_bin abs (fun oc ->
      Out_channel.output_string oc contents)

let with_repo f =
  Eio_main.run @@ fun env ->
  let proc = Eio.Stdenv.process_mgr env in
  let fs = Eio.Stdenv.fs env in
  let dir = Filename.temp_dir "spice_review_git" "" in
  Fun.protect ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
  @@ fun () ->
  let git args =
    Eio.Process.run proc
      ("git" :: "-C" :: dir :: "-c" :: "user.name=Alice Smith" :: "-c"
     :: "user.email=alice@example.com" :: args)
  in
  git [ "init"; "-q" ];
  git [ "config"; "user.name"; "Alice Smith" ];
  git [ "config"; "user.email"; "alice@example.com" ];
  write dir "lib/a.ml" "let a = 1\nlet b = 2\nlet c = 3\n";
  write dir "keep.txt" "unchanged\n";
  write dir "gone.txt" "to delete\n";
  git [ "add"; "-A" ];
  git [ "commit"; "-q"; "-m"; "init" ];
  f ~proc ~fs ~dir ~git

let mutate_worktree ~dir ~git =
  (* Modify with a CR, add a tracked file with a CR, delete a tracked file,
     add a tracked binary file, and leave an untracked file behind. *)
  write dir "lib/a.ml"
    "let a = 1\n(* CR alice: tighten this *)\nlet b = 2\nlet c = 3\n";
  write dir "new.ml" "(* CR bob: document this *)\nlet fresh = true\n";
  write dir "bin.dat" "\xff\xfe\x00\x01binary";
  Sys.remove (Filename.concat dir "gone.txt");
  write dir "untracked.txt" "joins the review as an addition\n";
  write dir ".spice/state.json" "{}";
  git [ "add"; "new.ml"; "bin.dat" ]

let discovery_and_base_resolution () =
  with_repo @@ fun ~proc ~fs ~dir ~git:_ ->
  let repo =
    expect_ok "discover from a subdirectory"
      (Git.discover ~proc ~fs ~cwd:(Filename.concat dir "lib"))
  in
  equal string ~msg:"root is the worktree root" (Unix.realpath dir)
    (Unix.realpath (Git.root repo));
  let base = expect_ok "resolve HEAD" (Git.resolve_base repo "HEAD") in
  equal int ~msg:"full commit hash" 40 (String.length base);
  (match Git.resolve_base repo "no-such-revision" with
  | Ok _ -> failf "expected a bad revision error"
  | Error error -> (
      match Git.Error.kind error with
      | Git.Error.Bad_revision _ -> ()
      | _ -> failf "unexpected error: %a" Git.Error.pp error));
  let outside = Filename.temp_dir "spice_review_git_not_a_repo" "" in
  Fun.protect ~finally:(fun () ->
      ignore (Sys.command ("rm -rf " ^ Filename.quote outside)))
  @@ fun () ->
  match Git.discover ~proc ~fs ~cwd:outside with
  | Ok _ -> failf "expected not-a-repository"
  | Error error -> (
      match Git.Error.kind error with
      | Git.Error.Not_a_repository -> ()
      | _ -> failf "unexpected error: %a" Git.Error.pp error)

let user_handle_is_sanitized () =
  with_repo @@ fun ~proc ~fs ~dir ~git:_ ->
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  equal string ~msg:"whitespace becomes dashes" "Alice-Smith"
    (Spice_cr.Handle.to_string (Git.user_handle repo))

let load_worktree_snapshot () =
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  mutate_worktree ~dir ~git;
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let load = expect_ok "load" (Git.load repo ~base) in
  let files = Review.Feature.files load.Review.Live.feature in
  let paths =
    List.map
      (fun file -> Spice_path.Rel.to_string (Review.Feature.File.path file))
      files
  in
  equal (list string)
    ~msg:"changed files in path order, untracked included as additions"
    [ "bin.dat"; "gone.txt"; "lib/a.ml"; "new.ml"; "untracked.txt" ]
    paths;
  let statuses =
    List.map
      (fun file ->
        match Review.Feature.File.status file with
        | Review.Feature.File.Added -> "added"
        | Review.Feature.File.Deleted -> "deleted"
        | Review.Feature.File.Modified -> "modified")
      files
  in
  equal (list string) ~msg:"statuses"
    [ "added"; "deleted"; "modified"; "added"; "added" ]
    statuses;
  (match Review.Feature.File.content (List.hd files) with
  | Review.Feature.File.Opaque `Binary -> ()
  | _ -> failf "expected the binary file to be opaque");
  equal string ~msg:"tip label" "WORKTREE"
    (Review.Feature.tip load.Review.Live.feature);
  equal string ~msg:"base label is the commit" base
    (Review.Feature.base load.Review.Live.feature);
  (* CRs come in feature file order: lib/a.ml before new.ml. *)
  let cr_paths =
    List.map
      (fun occ -> Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
      load.Review.Live.crs
  in
  equal (list string) ~msg:"CR occurrences in feature file order"
    [ "lib/a.ml"; "new.ml" ] cr_paths

let fingerprints_and_load_if_changed () =
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  mutate_worktree ~dir ~git;
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let first = expect_ok "fingerprint" (Git.fingerprint repo ~base) in
  let second = expect_ok "fingerprint again" (Git.fingerprint repo ~base) in
  equal string ~msg:"fingerprints are stable" first second;
  let load = expect_ok "load" (Git.load repo ~base) in
  equal string ~msg:"load carries the fingerprint" first
    load.Review.Live.fingerprint;
  (match
     expect_ok "load_if_changed with the known fingerprint"
       (Git.load_if_changed repo ~base ~known:(Some first))
   with
  | `Unchanged -> ()
  | `Loaded _ -> failf "expected unchanged");
  (* A new untracked file is reviewable content: it must reload. *)
  write dir "another-untracked.txt" "noise\n";
  (match
     expect_ok "load_if_changed after an untracked file appears"
       (Git.load_if_changed repo ~base ~known:(Some first))
   with
  | `Loaded reloaded ->
      is_true ~msg:"untracked file joins the review"
        (List.exists
           (fun file ->
             String.equal
               (Spice_path.Rel.to_string (Review.Feature.File.path file))
               "another-untracked.txt")
           (Review.Feature.files reloaded.Review.Live.feature))
  | `Unchanged -> failf "expected a reload for a new untracked file");
  (* A tracked edit reloads too. *)
  let second = expect_ok "fingerprint" (Git.fingerprint repo ~base) in
  write dir "lib/a.ml" "let a = 1\nlet b = 2\nlet c = 4\n";
  match
    expect_ok "load_if_changed after a tracked edit"
      (Git.load_if_changed repo ~base ~known:(Some second))
  with
  | `Loaded reloaded ->
      is_true ~msg:"fingerprint moved"
        (not (String.equal second reloaded.Review.Live.fingerprint))
  | `Unchanged -> failf "expected a reload"

let tracked_meta_files_are_excluded () =
  (* [load_worktree_snapshot] pins that an *untracked* .spice file is excluded;
     this pins the symmetric tracked side: a committed meta file that is then
     edited must not review itself, while an ordinary tracked edit still does. *)
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  write dir ".spice/state.json" "{\"revision\":1}";
  git [ "add"; "-A" ];
  git [ "commit"; "-q"; "-m"; "track a meta file" ];
  write dir ".spice/state.json" "{\"revision\":2}";
  write dir "lib/a.ml" "let a = 1\nlet b = 2\nlet c = 4\n";
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let load = expect_ok "load" (Git.load repo ~base) in
  let paths =
    List.map
      (fun file -> Spice_path.Rel.to_string (Review.Feature.File.path file))
      (Review.Feature.files load.Review.Live.feature)
  in
  is_true ~msg:"tracked meta edit is excluded from the feature"
    (not (List.mem ".spice/state.json" paths));
  is_true ~msg:"an ordinary tracked edit still reviews"
    (List.mem "lib/a.ml" paths)

let stats_projection () =
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  mutate_worktree ~dir ~git;
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let stats = expect_ok "stats" (Git.stats repo ~base) in
  (* lib/a.ml +1, new.ml +2, bin.dat binary (0/0), gone.txt -1, untracked.txt
     +1; the untracked .spice meta file is excluded. *)
  equal int ~msg:"files matches the reviewed set, meta excluded" 5
    stats.Spice_diff.files;
  equal int ~msg:"additions across tracked and untracked" 4
    stats.Spice_diff.additions;
  equal int ~msg:"deletions from the removed file" 1 stats.Spice_diff.deletions;
  (* The glance file count agrees with the full load's feature. *)
  let load = expect_ok "load" (Git.load repo ~base) in
  equal int ~msg:"stats agrees with load on the file count"
    (List.length (Review.Feature.files load.Review.Live.feature))
    stats.Spice_diff.files

let crs_scan () =
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  mutate_worktree ~dir ~git;
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let occurrences = expect_ok "crs" (Git.crs repo ~base) in
  let paths =
    List.map
      (fun occ -> Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
      occurrences
  in
  equal (list string)
    ~msg:"CR occurrences from changed non-deleted files, in feature file order"
    [ "lib/a.ml"; "new.ml" ] paths;
  (* The cheap scan yields the same occurrences the full load carries. *)
  let load = expect_ok "load" (Git.load repo ~base) in
  equal (list string) ~msg:"crs agrees with load's occurrence paths"
    (List.map
       (fun occ -> Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
       load.Review.Live.crs)
    paths;
  (* The CRs address the recipients "alice" and "bob"; both are open. *)
  let alice =
    match Spice_cr.Handle.of_string "alice" with
    | Ok handle -> handle
    | Error error -> failf "handle: %a" Spice_cr.Error.pp error
  in
  let counts = Spice_cr.Occurrence.counts ~handle:alice occurrences in
  equal int ~msg:"both scanned CRs are open" 2 counts.Spice_cr.Occurrence.open_;
  equal int ~msg:"one CR is addressed to alice" 1
    counts.Spice_cr.Occurrence.addressed

let glance_short_circuits_when_unchanged () =
  with_repo @@ fun ~proc ~fs ~dir ~git ->
  mutate_worktree ~dir ~git;
  let repo = expect_ok "discover" (Git.discover ~proc ~fs ~cwd:dir) in
  let base = expect_ok "resolve" (Git.resolve_base repo "HEAD") in
  let first =
    match expect_ok "glance" (Git.glance_if_changed repo ~base ~known:None) with
    | `Loaded glance -> glance
    | `Unchanged -> failf "first glance must load"
  in
  (* The combined glance carries the same facts as the single-fact queries. *)
  equal int ~msg:"glance stats agree with stats" 5
    first.Git.stats.Spice_diff.files;
  equal (list string) ~msg:"glance crs agree with crs" [ "lib/a.ml"; "new.ml" ]
    (List.map
       (fun occ -> Spice_path.Rel.to_string (Spice_cr.Occurrence.path occ))
       first.Git.crs);
  (* A poll with the last fingerprint short-circuits. *)
  (match
     expect_ok "unchanged glance"
       (Git.glance_if_changed repo ~base ~known:(Some first.Git.fingerprint))
   with
  | `Unchanged -> ()
  | `Loaded _ -> failf "an unchanged worktree must short-circuit");
  (* A tracked edit reloads with a moved fingerprint. *)
  write dir "lib/a.ml" "let a = 1\nlet b = 2\nlet c = 5\n";
  match
    expect_ok "changed glance"
      (Git.glance_if_changed repo ~base ~known:(Some first.Git.fingerprint))
  with
  | `Loaded reloaded ->
      is_true ~msg:"fingerprint moved on a tracked edit"
        (not (String.equal reloaded.Git.fingerprint first.Git.fingerprint))
  | `Unchanged -> failf "a changed worktree must reload"

let () =
  run "spice.review_git"
    [
      test "discovery and base resolution" discovery_and_base_resolution;
      test "user handle is sanitized" user_handle_is_sanitized;
      test "loads the worktree snapshot" load_worktree_snapshot;
      test "tracked meta files are excluded" tracked_meta_files_are_excluded;
      test "stats projection" stats_projection;
      test "crs scan" crs_scan;
      test "glance short-circuits when unchanged"
        glance_short_circuits_when_unchanged;
      test "fingerprints and load_if_changed" fingerprints_and_load_if_changed;
    ]
