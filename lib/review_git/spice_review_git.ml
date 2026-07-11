(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src =
  Logs.Src.create "spice.review_git" ~doc:"Loading review data from git"

module Log = (val Logs.src_log log_src : Logs.LOG)

(* Keep logged stderr fragments bounded per the logging conventions. *)
let log_truncate ?(max = 200) s =
  if String.length s > max then String.sub s 0 max ^ "..." else s

module Error = struct
  type kind =
    | Not_a_repository
    | Bad_revision of string
    | Git_failed of string
    | Raced
    | Io of string

  type t = { kind : kind; message : string }

  let make kind message = { kind; message }
  let kind t = t.kind
  let message t = t.message
  let pp ppf t = Format.pp_print_string ppf t.message
end

type run = cwd:string -> string list -> (string, string) result
type fs = Fs : _ Eio.Path.t -> fs
type t = { run : run; fs : fs; root : string }

let root t = t.root

let git_output ?cwd t args =
  let directory = Option.value cwd ~default:t.root in
  let start = Unix.gettimeofday () in
  match t.run ~cwd:directory args with
  | Ok output ->
      Log.debug (fun m ->
          m "git %s ok duration=%.0fms bytes=%d" (String.concat " " args)
            ((Unix.gettimeofday () -. start) *. 1000.)
            (String.length output));
      Ok output
  | Error stderr ->
      let stderr = String.trim stderr in
      Log.debug (fun m ->
          m "git %s failed duration=%.0fms stderr=%s" (String.concat " " args)
            ((Unix.gettimeofday () -. start) *. 1000.)
            (log_truncate stderr));
      Error
        (if String.length stderr > 0 then stderr
         else "git " ^ String.concat " " args ^ " failed")

let git_failed message = Error (Error.make (Error.Git_failed message) message)

let discover ~run ~fs ~cwd =
  let probe = { run; fs = Fs fs; root = cwd } in
  match git_output ~cwd probe [ "rev-parse"; "--show-toplevel" ] with
  | Ok output -> (
      match String.split_on_char '\n' (String.trim output) with
      | root :: _ when String.length root > 0 ->
          Log.debug (fun m -> m "discovered worktree root=%s" root);
          Ok { probe with root }
      | _ ->
          Error
            (Error.make Error.Not_a_repository
               "git did not report a worktree root"))
  | Error message ->
      Error
        (Error.make Error.Not_a_repository
           (Printf.sprintf "%s is not inside a git worktree: %s" cwd message))

let resolve_base t spec =
  match
    git_output t [ "rev-parse"; "--verify"; "--quiet"; spec ^ "^{commit}" ]
  with
  | Ok output ->
      let hash = String.trim output in
      if String.length hash > 0 then Ok hash
      else
        Error
          (Error.make (Error.Bad_revision spec)
             (Printf.sprintf "unknown base revision %s" spec))
  | Error _ ->
      Error
        (Error.make (Error.Bad_revision spec)
           (Printf.sprintf "unknown base revision %s" spec))

let fallback_handle =
  match Spice_cr.Handle.of_string "user" with
  | Ok handle -> handle
  | Error _ -> assert false

let user_handle t =
  match git_output t [ "config"; "user.name" ] with
  | Error _ ->
      Log.warn (fun m ->
          m "git config user.name unavailable, using fallback handle");
      fallback_handle
  | Ok output -> (
      let sanitized =
        String.map
          (fun char ->
            match char with ' ' | '\t' | '\n' | '\r' | ':' -> '-' | _ -> char)
          (String.trim output)
      in
      match Spice_cr.Handle.of_string sanitized with
      | Ok handle -> handle
      | Error _ ->
          Log.warn (fun m ->
              m "git user.name %S is not a valid handle, using fallback"
                sanitized);
          fallback_handle)

let diff_args base = [ "diff"; "--no-color"; "--no-ext-diff"; base ]

let rel_paths ~context fields =
  let rec collect = function
    | [] -> Ok []
    | path :: rest -> (
        match collect rest with
        | Error _ as error -> error
        | Ok tail -> (
            match Spice_path.Rel.of_string path with
            | Error error ->
                git_failed
                  (Printf.sprintf "unexpected path %S in git %s output: %s" path
                     context
                     (Spice_path.Error.message error))
            | Ok rel -> Ok (rel :: tail)))
  in
  collect fields

let nul_fields output =
  List.filter
    (fun field -> String.length field > 0)
    (String.split_on_char '\000' output)

(* Workspace meta directories are never review content even when the
   repository does not gitignore them. Same set as the host watchers' default
   ignore. *)
let meta_path rel =
  List.exists
    (function ".git" | ".spice" | "_build" | "_opam" -> true | _ -> false)
    (String.split_on_char '/' (Spice_path.Rel.to_string rel))

(* Untracked files review as additions, as a working-tree diff does.
   [.gitignore]d paths stay excluded. *)
let untracked_paths t =
  match git_output t [ "ls-files"; "--others"; "--exclude-standard"; "-z" ] with
  | Error message -> git_failed message
  | Ok output -> (
      match rel_paths ~context:"ls-files" (nul_fields output) with
      | Error _ as error -> error
      | Ok paths -> Ok (List.filter (fun rel -> not (meta_path rel)) paths))

let add_frame buffer text =
  Buffer.add_string buffer (string_of_int (String.length text));
  Buffer.add_char buffer ':';
  Buffer.add_string buffer text

(* An equality token for the untracked set: paths plus content identities, so
   creating, deleting, or editing an untracked file moves the fingerprint even
   when a writer preserves mtimes. *)
let untracked_token t paths =
  let (Fs fs) = t.fs in
  let buffer = Buffer.create 256 in
  List.iter
    (fun rel ->
      let text = Spice_path.Rel.to_string rel in
      add_frame buffer text;
      match Eio.Path.load (Eio.Path.( / ) fs (Filename.concat t.root text)) with
      | contents ->
          add_frame buffer
            (Spice_digest.Identity.to_string
               (Spice_digest.Identity.of_contents contents))
      | exception _ -> add_frame buffer "absent")
    paths;
  Buffer.contents buffer

let fingerprint t ~base =
  match git_output t (diff_args base) with
  | Error message -> git_failed message
  | Ok output -> (
      match untracked_paths t with
      | Error _ as error -> error
      | Ok untracked ->
          Ok
            (Spice_digest.key ~length:64
               ~domain:"spice.review_git.fingerprint.v1"
               [ output; untracked_token t untracked ]))

(* Changed paths from [--name-status -z]: NUL-separated
   [status, path, status, path, ...] records, unquoted. Renames are disabled
   so every record has exactly one path. *)
let changed_paths t ~base =
  match
    git_output t
      [ "diff"; "--name-status"; "--no-renames"; "--no-ext-diff"; "-z"; base ]
  with
  | Error message -> git_failed message
  | Ok output -> (
      let fields = nul_fields output in
      let rec pair = function
        | [] -> Ok []
        | status :: path :: rest -> (
            match pair rest with
            | Error _ as error -> error
            | Ok tail -> (
                match Spice_path.Rel.of_string path with
                | Error error ->
                    git_failed
                      (Printf.sprintf "unexpected path %S in git output: %s"
                         path
                         (Spice_path.Error.message error))
                | Ok rel -> Ok ((status, rel) :: tail)))
        | [ field ] ->
            git_failed
              (Printf.sprintf "unpaired field %S in git name-status output"
                 field)
      in
      match pair fields with
      | Error _ as error -> error
      | Ok tracked -> (
          (* Meta directories are dropped from the feature on the tracked side
             too, matching [untracked_paths]; the raw fingerprint diff keeps the
             gap. *)
          let tracked =
            List.filter (fun (_, rel) -> not (meta_path rel)) tracked
          in
          match untracked_paths t with
          | Error _ as error -> error
          | Ok untracked ->
              Ok (tracked @ List.map (fun rel -> ("A", rel)) untracked)))

let base_blob t ~base ~path =
  match
    git_output t
      [ "cat-file"; "blob"; base ^ ":" ^ Spice_path.Rel.to_string path ]
  with
  | Ok contents -> Ok contents
  | Error message -> git_failed message

let worktree_text t ~path =
  let (Fs fs) = t.fs in
  match
    Eio.Path.load
      (Eio.Path.( / ) fs
         (Filename.concat t.root (Spice_path.Rel.to_string path)))
  with
  | contents -> Ok contents
  | exception exn ->
      Error
        (Error.make
           (Error.Io (Printexc.to_string exn))
           (Printexc.to_string exn))

let sides t ~base status path =
  match status with
  | "A" -> (
      match worktree_text t ~path with
      | Ok after -> Ok (None, Some after)
      | Error _ as error -> error)
  | "D" -> (
      match base_blob t ~base ~path with
      | Ok before -> Ok (Some before, None)
      | Error _ as error -> error)
  | _ -> (
      (* Modifications and type changes both read as modified content. *)
      match base_blob t ~base ~path with
      | Error _ as error -> error
      | Ok before -> (
          match worktree_text t ~path with
          | Ok after -> Ok (Some before, Some after)
          | Error _ as error -> error))

let scan_crs ~path text = Spice_cr.scan_file ~path ~text

let collect t ~base ~fingerprint:snapshot =
  match changed_paths t ~base with
  | Error _ as error -> error
  | Ok changed -> (
      let sorted =
        List.sort (fun (_, a) (_, b) -> Spice_path.Rel.compare a b) changed
      in
      let rec build files crs = function
        | [] -> Ok (List.rev files, List.rev_append crs [])
        | (status, path) :: rest -> (
            match sides t ~base status path with
            | Error _ as error -> error
            | Ok (before, after) -> (
                match
                  Spice_review.Feature.File.make ~path ~before ~after ()
                with
                | Error error ->
                    git_failed
                      (Printf.sprintf "cannot load %s: %s"
                         (Spice_path.Rel.to_string path)
                         (Format.asprintf "%a" Spice_review.Error.pp error))
                | Ok file ->
                    let file_crs =
                      match after with
                      | Some text -> scan_crs ~path text
                      | None -> []
                    in
                    build (file :: files) (List.rev_append file_crs crs) rest))
      in
      match build [] [] sorted with
      | Error _ as error -> error
      | Ok (files, crs) ->
          let feature = Spice_review.Feature.v ~base ~tip:"WORKTREE" files in
          Log.debug (fun m ->
              m "review loaded base=%s files=%d crs=%d" base (List.length files)
                (List.length crs));
          Ok { Spice_review.Live.feature; crs; fingerprint = snapshot })

let max_load_attempts = 3

let load t ~base =
  let rec attempt remaining =
    match fingerprint t ~base with
    | Error _ as error -> error
    | Ok snapshot -> (
        let retry error =
          if remaining > 1 then begin
            Log.warn (fun m ->
                m
                  "worktree changed during load, retrying attempts_left=%d \
                   reason=%s"
                  (remaining - 1) (Error.message error));
            attempt (remaining - 1)
          end
          else
            match (Error.kind error : Error.kind) with
            | Error.Io _ | Error.Raced ->
                Error
                  (Error.make Error.Raced
                     "the worktree kept changing while loading the review")
            | _ -> Error error
        in
        match collect t ~base ~fingerprint:snapshot with
        | Error error -> (
            match Error.kind error with
            | Error.Io _ -> retry error
            | _ -> Error error)
        | Ok load -> (
            match fingerprint t ~base with
            | Error _ as error -> error
            | Ok verify ->
                if String.equal verify snapshot then Ok load
                else retry (Error.make Error.Raced "worktree changed")))
  in
  attempt max_load_attempts

let load_if_changed t ~base ~known =
  match fingerprint t ~base with
  | Error _ as error -> error
  | Ok current -> (
      match known with
      | Some known when String.equal known current ->
          Log.debug (fun m -> m "worktree unchanged, skipping reload");
          Ok `Unchanged
      | Some _ | None -> (
          match load t ~base with
          | Ok load -> Ok (`Loaded load)
          | Error _ as error -> error))

(* One [git diff --numstat -z] record, [additions TAB deletions TAB path]. With
   renames disabled every record is a single path, so the two tabs split cleanly
   even when the path itself contains a tab. *)
let numstat_record field =
  match String.index_opt field '\t' with
  | None -> Error field
  | Some i1 -> (
      let additions = String.sub field 0 i1 in
      let rest = String.sub field (i1 + 1) (String.length field - i1 - 1) in
      match String.index_opt rest '\t' with
      | None -> Error field
      | Some i2 ->
          let deletions = String.sub rest 0 i2 in
          let path = String.sub rest (i2 + 1) (String.length rest - i2 - 1) in
          Ok (additions, deletions, path))

(* Binary changes report ["-"] for both counts; they still count as a changed
   file, with no line counts, like the review's opaque files. *)
let numstat_count field = function
  | "-" -> Ok 0
  | text -> (
      match int_of_string_opt text with
      | Some count when count >= 0 -> Ok count
      | Some _ | None ->
          Error
            (Printf.sprintf "unexpected count %S in git numstat field %S" text
               field))

let tracked_numstat t ~base =
  match
    git_output t
      [ "diff"; "--numstat"; "--no-renames"; "--no-ext-diff"; "-z"; base ]
  with
  | Error message -> git_failed message
  | Ok output ->
      let rec fold files additions deletions = function
        | [] -> Ok (files, additions, deletions)
        | field :: rest -> (
            match numstat_record field with
            | Error bad ->
                git_failed
                  (Printf.sprintf "unpaired field %S in git numstat output" bad)
            | Ok (add_field, del_field, path) -> (
                match Spice_path.Rel.of_string path with
                | Error error ->
                    git_failed
                      (Printf.sprintf
                         "unexpected path %S in git numstat output: %s" path
                         (Spice_path.Error.message error))
                | Ok rel -> (
                    if meta_path rel then fold files additions deletions rest
                    else
                      match numstat_count field add_field with
                      | Error message -> git_failed message
                      | Ok added -> (
                          match numstat_count field del_field with
                          | Error message -> git_failed message
                          | Ok removed ->
                              fold (files + 1) (additions + added)
                                (deletions + removed) rest))))
      in
      fold 0 0 0 (nul_fields output)

(* Untracked additions, counted with [Spice_diff]'s own line rule over the
   worktree text so they agree exactly with what [load] would add. *)
let untracked_stats t paths =
  let (Fs fs) = t.fs in
  let rec build acc = function
    | [] -> Ok (Spice_diff.stats_of_changes (List.rev acc))
    | rel :: rest -> (
        match
          Eio.Path.load
            (Eio.Path.( / ) fs
               (Filename.concat t.root (Spice_path.Rel.to_string rel)))
        with
        | exception exn ->
            Error
              (Error.make
                 (Error.Io (Printexc.to_string exn))
                 (Printexc.to_string exn))
        | contents ->
            let label =
              Spice_diff.Label.escaped (Spice_path.Rel.to_string rel)
            in
            build (Spice_diff.File_change.create ~label ~contents :: acc) rest)
  in
  build [] paths

let stats t ~base =
  match tracked_numstat t ~base with
  | Error _ as error -> error
  | Ok (tracked_files, tracked_additions, tracked_deletions) -> (
      match untracked_paths t with
      | Error _ as error -> error
      | Ok untracked -> (
          match untracked_stats t untracked with
          | Error _ as error -> error
          | Ok untracked_stats ->
              Ok
                (Spice_diff.stats_v
                   ~files:(tracked_files + untracked_stats.Spice_diff.files)
                   ~additions:
                     (tracked_additions + untracked_stats.Spice_diff.additions)
                   ~deletions:
                     (tracked_deletions + untracked_stats.Spice_diff.deletions))
          ))

let crs t ~base =
  match changed_paths t ~base with
  | Error _ as error -> error
  | Ok changed ->
      let sorted =
        List.sort (fun (_, a) (_, b) -> Spice_path.Rel.compare a b) changed
      in
      let rec build acc = function
        | [] -> Ok (List.rev acc)
        | (status, path) :: rest -> (
            if String.equal status "D" then build acc rest
            else
              match worktree_text t ~path with
              | Error _ as error -> error
              | Ok text ->
                  build (List.rev_append (scan_crs ~path text) acc) rest)
      in
      build [] sorted

type glance = {
  stats : Spice_diff.stats;
  crs : Spice_cr.Occurrence.t list;
  fingerprint : string;
}

(* Gate the whole projection on the shared fingerprint so an idle poll pays only
   the fingerprint probe. The probe (one [git diff] plus the untracked scan) is
   cheaper than the numstat, name-status, file reads, and CR scans a changed
   tick then runs, so short-circuiting on [known] is the win. No before/after
   guard: a glance tolerates a mid-scan skew the next tick corrects. *)
let glance_if_changed t ~base ~known =
  match fingerprint t ~base with
  | Error _ as error -> error
  | Ok current -> (
      match known with
      | Some known when String.equal known current -> Ok `Unchanged
      | Some _ | None -> (
          match stats t ~base with
          | Error _ as error -> error
          | Ok stats -> (
              match crs t ~base with
              | Error _ as error -> error
              | Ok crs -> Ok (`Loaded { stats; crs; fingerprint = current }))))

module Records = struct
  let key ~base =
    Spice_digest.key ~length:16 ~domain:"spice.review_git.worktree-record.v1"
      [ base ]

  let path dir key = Filename.concat dir (key ^ ".json")
  let keep = 20

  let load ~fs ~dir ~key =
    match Eio.Path.load (Eio.Path.( / ) fs (path dir key)) with
    | exception _ -> None
    | text -> (
        match Jsont_bytesrw.decode_string Spice_review.Persist.jsont text with
        | Ok record -> Some record
        | Error _ -> None)

  (* Prune to the newest [keep] records by mtime; a failed unlink only leaves
     an extra record behind. *)
  let prune ~fs dir =
    match Eio.Path.read_dir (Eio.Path.( / ) fs dir) with
    | exception _ -> ()
    | entries ->
        let records =
          List.filter_map
            (fun entry ->
              if Filename.check_suffix entry ".json" then
                let path = Filename.concat dir entry in
                match Eio.Path.stat ~follow:false (Eio.Path.( / ) fs path) with
                | exception _ -> None
                | stat -> Some (stat.Eio.File.Stat.mtime, path)
              else None)
            entries
        in
        if List.length records > keep then
          let sorted =
            List.sort (fun (a, _) (b, _) -> Float.compare b a) records
          in
          List.iteri
            (fun index (_, path) ->
              if index >= keep then
                try Eio.Path.unlink (Eio.Path.( / ) fs path)
                with exn ->
                  Log.debug (fun m ->
                      m "review record prune unlink failed: %s"
                        (Printexc.to_string exn)))
            sorted

  let save ~fs ~dir ~key record =
    match Jsont_bytesrw.encode_string Spice_review.Persist.jsont record with
    | Error message -> Error message
    | Ok text -> (
        match
          Eio.Path.mkdirs ~exists_ok:true ~perm:0o700
            (Eio.Path.( / ) fs dir)
        with
        | exception exn -> Error (Printexc.to_string exn)
        | () -> (
            let target = path dir key in
            let tmp = target ^ ".tmp" in
            (try Eio.Path.unlink (Eio.Path.( / ) fs tmp)
             with exn ->
               Log.debug (fun m ->
                   m "review record stale tmp unlink failed: %s"
                     (Printexc.to_string exn)));
            match
              Eio.Path.save ~create:(`Exclusive 0o600) (Eio.Path.( / ) fs tmp)
                text;
              Eio.Path.rename (Eio.Path.( / ) fs tmp) (Eio.Path.( / ) fs target)
            with
            | exception exn -> Error (Printexc.to_string exn)
            | () ->
                Log.debug (fun m -> m "review record saved key=%s" key);
                prune ~fs dir;
                Ok ()))
end

type apply_error = Stale_worktree | Apply_failed of string

let apply_op t ~base ~expected op =
  let (Fs fs) = t.fs in
  let cr_message error = Format.asprintf "%a" Spice_cr.Error.pp error in
  match fingerprint t ~base with
  | Error error -> Error (Apply_failed (Error.message error))
  | Ok current when not (String.equal current expected) -> Error Stale_worktree
  | Ok _ -> (
      let rel = Spice_review.Op.path op in
      let abs = Filename.concat t.root (Spice_path.Rel.to_string rel) in
      match Eio.Path.load (Eio.Path.( / ) fs abs) with
      | exception exn -> Error (Apply_failed (Printexc.to_string exn))
      | text -> (
          let edited =
            match op with
            | Spice_review.Op.Add { line; cr; _ } -> (
                match Spice_cr.Syntax.of_path rel with
                | None ->
                    Error
                      (Printf.sprintf "%s has no conventional comment syntax"
                         (Spice_path.Rel.to_string rel))
                | Some syntax ->
                    Result.map_error cr_message
                      (Spice_cr.add_before_line ~syntax ~text ~line cr))
            | Spice_review.Op.Replace { occurrence; cr } ->
                Result.map_error cr_message
                  (Spice_cr.replace ~text occurrence cr)
            | Spice_review.Op.Remove { occurrence } ->
                Result.map_error cr_message (Spice_cr.remove ~text occurrence)
          in
          match edited with
          | Error message -> Error (Apply_failed message)
          | Ok edited -> (
              let tmp = abs ^ ".spice-cr.tmp" in
              (try Eio.Path.unlink (Eio.Path.( / ) fs tmp)
               with exn ->
                 Log.debug (fun m ->
                     m "cr-edit stale tmp unlink failed: %s"
                       (Printexc.to_string exn)));
              match
                Eio.Path.save ~create:(`Exclusive 0o600) (Eio.Path.( / ) fs tmp)
                  edited;
                Eio.Path.rename (Eio.Path.( / ) fs tmp) (Eio.Path.( / ) fs abs)
              with
              | exception exn -> Error (Apply_failed (Printexc.to_string exn))
              | () -> (
                  match load t ~base with
                  | Error error -> Error (Apply_failed (Error.message error))
                  | Ok load -> Ok load))))
