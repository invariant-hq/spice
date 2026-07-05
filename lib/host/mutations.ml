(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Log = struct
  type t = { fs : Eio.Fs.dir_ty Eio.Path.t; root : string }

  let make ~fs ~root = { fs; root }
  let fs_path t path = Eio.Path.( / ) t.fs path

  let session_dir t id =
    Filename.concat
      (Filename.concat t.root "sessions")
      (Spice_session.Id.to_string id)

  let ledger_path t id = Filename.concat (session_dir t id) "mutations.jsonl"
  let lock_path t id = Filename.concat (session_dir t id) "mutations.lock"
  let blobs_dir t = Filename.concat t.root "blobs"

  let blob_path t identity =
    (* Shard by a fresh hash of the identity string, not a prefix of it:
       [Identity.to_string] carries a constant [sha256:] prefix, so slicing
       leading characters would collapse the whole store into one shard. The
       fresh hash distributes uniformly. Changing this function re-shards the
       store and orphans every existing blob at its old path. *)
    let text = Spice_digest.Identity.to_string identity in
    let name = String.map (function ':' -> '-' | c -> c) text in
    let shard = Spice_digest.key ~length:2 [ text ] in
    Filename.concat (Filename.concat (blobs_dir t) shard) name

  let io path f =
    match f () with
    | value -> Ok value
    | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)

  let mkdir_p t dir =
    io dir (fun () ->
        try Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path t dir)
        with Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> ())

  let exists t path =
    match Eio.Path.kind ~follow:true (fs_path t path) with
    | `Not_found -> false
    | _ -> true
    | exception _ -> false

  let load_opt t path =
    match Eio.Path.load (fs_path t path) with
    | contents -> Ok (Some contents)
    | exception Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> Ok None
    | exception exn -> Error (path ^ ": " ^ Printexc.to_string exn)

  let tmp_counter = ref 0

  let tmp_path path =
    incr tmp_counter;
    path ^ ".tmp."
    ^ string_of_int (Unix.getpid ())
    ^ "." ^ string_of_int !tmp_counter

  let atomic_write t path contents =
    let ( let* ) = Result.bind in
    let* () = mkdir_p t (Filename.dirname path) in
    let tmp = tmp_path path in
    let* () =
      io tmp (fun () ->
          Eio.Path.save ~create:(`Exclusive 0o600) (fs_path t tmp) contents)
    in
    io path (fun () -> Eio.Path.rename (fs_path t tmp) (fs_path t path))

  let with_lock t path f =
    let rec lockf fd command =
      match Unix.lockf fd command 0 with
      | () -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> lockf fd command
    in
    let ( let* ) = Result.bind in
    let* () = mkdir_p t (Filename.dirname path) in
    let* native = io path (fun () -> Eio.Path.native_exn (fs_path t path)) in
    io path (fun () ->
        let fd =
          Unix.openfile native
            [ Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC ]
            0o600
        in
        Fun.protect
          ~finally:(fun () -> Unix.close fd)
          (fun () ->
            (* F_LOCK blocks while another process holds the lock; take it in
               a systhread so the Eio domain keeps running. *)
            Eio_unix.run_in_systhread ~label:"spice-file-lock" (fun () ->
                lockf fd Unix.F_LOCK);
            Fun.protect ~finally:(fun () -> lockf fd Unix.F_ULOCK) f))
    |> Result.join

  let put_blob t contents =
    let ( let* ) = Result.bind in
    let identity = Spice_digest.Identity.of_contents contents in
    let path = blob_path t identity in
    if exists t path then Ok identity
    else
      let* () = atomic_write t path contents in
      Ok identity

  let blob t identity = load_opt t (blob_path t identity)

  let encode_record record =
    match Jsont_bytesrw.encode_string Spice_mutation.Record.jsont record with
    | Ok text -> Ok text
    | Error message -> Error ("encode mutation record: " ^ message)

  let decode_record path line =
    match Jsont_bytesrw.decode_string Spice_mutation.Record.jsont line with
    | Ok record -> Ok record
    | Error message -> Error (path ^ ": corrupt mutation record: " ^ message)

  let encode_records records =
    let ( let* ) = Result.bind in
    List.fold_left
      (fun acc record ->
        let* lines = acc in
        let* line = encode_record record in
        Ok (line :: lines))
      (Ok []) records
    |> Result.map List.rev

  let append t ~session records =
    match records with
    | [] -> Ok ()
    | records ->
        let ( let* ) = Result.bind in
        let* lines = encode_records records in
        let path = ledger_path t session in
        with_lock t (lock_path t session) (fun () ->
            let* existing = load_opt t path in
            let existing = Option.value existing ~default:"" in
            let appended =
              existing ^ String.concat "" (List.map (fun l -> l ^ "\n") lines)
            in
            atomic_write t path appended)

  let read t ~session =
    let ( let* ) = Result.bind in
    let path = ledger_path t session in
    let* contents = load_opt t path in
    match contents with
    | None -> Ok []
    | Some contents ->
        String.split_on_char '\n' contents
        |> List.filter (fun line -> not (String.equal line ""))
        |> List.fold_left
             (fun acc line ->
               let* records = acc in
               let* record = decode_record path line in
               Ok (record :: records))
             (Ok [])
        |> Result.map List.rev
end

module Backend = struct
  type capture = { reference : string; excluded : int }

  type t = {
    name : string;
    capture : unit -> (capture, string) result;
    paths :
      from_:string ->
      to_:string ->
      ( (Spice_path.Rel.t * [ `Added | `Modified | `Deleted ]) list,
        string )
      result;
    read :
      reference:string ->
      Spice_path.Rel.t ->
      (Spice_edit.Observed.t, string) result;
  }

  let shadow_config =
    [
      ("core.autocrlf", "false");
      ("core.symlinks", "true");
      ("core.longpaths", "true");
      ("core.fsmonitor", "false");
      ("core.untrackedCache", "true");
      ("feature.manyFiles", "true");
      ("index.version", "4");
      ("index.threads", "true");
    ]

  let ignored_checkpoint_path path =
    let path = Spice_path.Rel.to_string path in
    String.equal path "_build"
    || String.starts_with ~prefix:"_build/" path
    || String.equal path "_opam"
    || String.starts_with ~prefix:"_opam/" path

  let git_tree ~fs ~run ~data_root ~workspace_root () =
    let ( let* ) = Result.bind in
    let inside_work_tree =
      match
        run
          [ "git"; "-C"; workspace_root; "rev-parse"; "--is-inside-work-tree" ]
      with
      | Ok answer -> String.equal (String.trim answer) "true"
      | Error _ -> false
    in
    if not inside_work_tree then None
    else
      let key = Spice_digest.key ~length:16 [ workspace_root ] in
      let git_dir =
        Filename.concat (Filename.concat data_root "checkpoints") key
      in
      let git args = run ([ "git"; "--git-dir"; git_dir ] @ args) in
      let git_work args =
        run
          ([ "git"; "--git-dir"; git_dir; "--work-tree"; workspace_root ] @ args)
      in
      let initialized =
        match Eio.Path.kind ~follow:true (Eio.Path.( / ) fs git_dir) with
        | `Directory -> Ok ()
        | _ -> (
            let* _ = run [ "git"; "init"; "--quiet"; "--bare"; git_dir ] in
            let* () =
              List.fold_left
                (fun acc (key, value) ->
                  let* () = acc in
                  let* _ = git [ "config"; key; value ] in
                  Ok ())
                (Ok ()) shadow_config
            in
            (* Share the workspace object database so unchanged blobs are
               never re-hashed or duplicated. *)
            let* objects =
              run
                [
                  "git";
                  "-C";
                  workspace_root;
                  "rev-parse";
                  "--git-path";
                  "objects";
                ]
            in
            let alternates =
              Filename.concat (Filename.concat git_dir "objects") "info"
            in
            (match
               Eio.Path.mkdirs ~exists_ok:true ~perm:0o700
                 (Eio.Path.( / ) fs alternates)
             with
            | () -> ()
            | exception _ -> ());
            let* () =
              match
                Eio.Path.save ~create:(`Or_truncate 0o600)
                  (Eio.Path.( / ) fs (Filename.concat alternates "alternates"))
                  (String.trim objects ^ "\n")
              with
              | () -> Ok ()
              | exception exn -> Error ("alternates: " ^ Printexc.to_string exn)
            in
            (* The snapshot system must never snapshot its own sidecar:
               when the host data root lives inside the workspace (the
               default workspace-local store), exclude it from capture and
               attribution. *)
            let generated_excludes = [ "/_build/"; "/_opam/" ] in
            let excludes =
              let prefix = workspace_root ^ Filename.dir_sep in
              if String.starts_with ~prefix data_root then
                let relative =
                  String.drop_first (String.length prefix) data_root
                in
                ("/" ^ relative ^ "/") :: generated_excludes
              else generated_excludes
            in
            let info_dir = Filename.concat git_dir "info" in
            (match
               Eio.Path.mkdirs ~exists_ok:true ~perm:0o700
                 (Eio.Path.( / ) fs info_dir)
             with
            | () -> ()
            | exception _ -> ());
            match
              Eio.Path.save ~create:(`Or_truncate 0o600)
                (Eio.Path.( / ) fs (Filename.concat info_dir "exclude"))
                (String.concat "" (List.map (fun e -> e ^ "\n") excludes))
            with
            | () -> Ok ()
            | exception exn -> Error ("exclude: " ^ Printexc.to_string exn))
        | exception exn -> Error (git_dir ^ ": " ^ Printexc.to_string exn)
      in
      let ensure () = initialized in
      let capture () =
        let* () = ensure () in
        let* _ = git_work [ "add"; "--all" ] in
        let* tree = git [ "write-tree" ] in
        Ok { reference = String.trim tree; excluded = 0 }
      in
      let parse_status line =
        match String.split_first ~sep:"\t" line with
        | None -> None
        | Some (status, path) -> (
            match Spice_path.Rel.of_string path with
            | Error _ -> None
            | Ok rel -> (
                match status with
                | "A" -> Some (rel, `Added)
                | "D" -> Some (rel, `Deleted)
                | _ -> Some (rel, `Modified)))
      in
      let paths ~from_ ~to_ =
        let* output =
          git
            [
              "diff";
              "--name-status";
              "--no-renames";
              "--no-ext-diff";
              from_;
              to_;
            ]
        in
        String.split_on_char '\n' output
        |> List.filter_map parse_status
        |> List.filter (fun (path, _) -> not (ignored_checkpoint_path path))
        |> Result.ok
      in
      let read ~reference path =
        let spec = reference ^ ":" ^ Spice_path.Rel.to_string path in
        let* listing =
          git [ "ls-tree"; reference; "--"; Spice_path.Rel.to_string path ]
        in
        let listing = String.trim listing in
        let is_blob =
          (* ls-tree lines are "<mode> <type> <hash>\t<path>". *)
          match String.split_on_char ' ' listing with
          | _mode :: kind :: _ -> String.equal kind "blob"
          | _ -> false
        in
        if String.equal listing "" then Ok Spice_edit.Observed.Missing
        else if not is_blob then
          (* Tree entries (directories, gitlinks) are not editable text
             files. *)
          Ok Spice_edit.Observed.Other
        else
          let* contents = git [ "cat-file"; "blob"; spec ] in
          if String.is_valid_utf_8 contents then
            Ok (Spice_edit.Observed.Text contents)
          else Ok Spice_edit.Observed.Other
      in
      Some { name = "git_tree"; capture; paths; read }
end

type recorder = {
  log : Log.t;
  backend : Backend.t option;
  workspace_root : string;
}

let recorder ~log ?checkpoint ~workspace_root () =
  { log; backend = checkpoint; workspace_root }

let has_checkpoint_backend t = Option.is_some t.backend
let read t ~session = Log.read t.log ~session
let append t ~session records = Log.append t.log ~session records

let record_checkpoint t ~session ~turn ~reason =
  match t.backend with
  | None -> Ok None
  | Some backend -> (
      let id = Spice_mutation.Checkpoint.derive_id ~session ~turn ~reason in
      let status =
        match backend.Backend.capture () with
        | Ok { Backend.reference; excluded } ->
            Spice_mutation.Checkpoint.Available
              { backend = backend.Backend.name; reference; excluded }
        | Error message ->
            Spice_mutation.Checkpoint.Degraded
              { backend = backend.Backend.name; message }
      in
      let fact =
        Spice_mutation.Checkpoint.make ~id ~session ~turn ~root:t.workspace_root
          ~reason ~status
      in
      match append t ~session [ Spice_mutation.Record.Checkpoint fact ] with
      | Ok () -> Ok (Some fact)
      | Error _ as error -> error)

let target_text target =
  match (target : Spice_edit.Observed.t) with
  | Spice_edit.Observed.Text contents -> Some contents
  | Spice_edit.Observed.Missing | Spice_edit.Observed.Other -> None

let row_stats ~path ~before ~after =
  let label = Spice_diff.Label.of_string (Spice_path.Rel.to_string path) in
  match Spice_diff.File_change.of_states ~label ~before ~after with
  | None -> (0, 0)
  | Some change ->
      let stats = Spice_diff.stats_of_changes [ change ] in
      (stats.Spice_diff.additions, stats.Spice_diff.deletions)

let stored_image log target =
  let ( let* ) = Result.bind in
  match (target : Spice_edit.Observed.t) with
  | Spice_edit.Observed.Text contents ->
      let* (_ : Spice_digest.Identity.t) = Log.put_blob log contents in
      Ok (Spice_mutation.Image.of_target target)
  | Spice_edit.Observed.Missing | Spice_edit.Observed.Other ->
      Ok (Spice_mutation.Image.of_target target)

let revertability ~before ~after =
  let supported = function
    | Spice_mutation.Image.Missing | Spice_mutation.Image.Text _ -> true
    | Spice_mutation.Image.Unsupported _ -> false
  in
  if supported before && supported after then Spice_mutation.Change.Revertable
  else Spice_mutation.Change.Not_revertable "not a regular UTF-8 text file"

let row ~log ~session ~turn ~execution_id ~source ?checkpoint ~index ~path ~op
    ~before_target ~after_target () =
  let ( let* ) = Result.bind in
  let* before = stored_image log before_target in
  let* after = stored_image log after_target in
  let additions, deletions =
    row_stats ~path
      ~before:(target_text before_target)
      ~after:(target_text after_target)
  in
  Ok
    (Spice_mutation.Change.make ?checkpoint
       ~id:
         (Spice_mutation.Change.derive_id ~execution:execution_id ~path ~index)
       ~session ~turn ~source ~path ~op ~before ~after ~additions ~deletions
       ~revertability:(revertability ~before ~after)
       ())

let rec traverse f = function
  | [] -> Ok []
  | item :: items ->
      let ( let* ) = Result.bind in
      let* value = f item in
      let* values = traverse f items in
      Ok (value :: values)

let change_op = function
  | Spice_tools.Receipt.Create -> Spice_mutation.Change.Create
  | Spice_tools.Receipt.Modify -> Spice_mutation.Change.Modify
  | Spice_tools.Receipt.Delete -> Spice_mutation.Change.Delete
  | Spice_tools.Receipt.Move { from } ->
      Spice_mutation.Change.Move { from = Spice_workspace.Path.rel from }

let rows_of_receipt ~log ~session ~turn ~execution_id ~source ?checkpoint
    (receipt : Spice_tools.Receipt.t) =
  let index = ref (-1) in
  traverse
    (fun (change : Spice_tools.Receipt.change) ->
      incr index;
      row ~log ~session ~turn ~execution_id ~source ?checkpoint ~index:!index
        ~path:(Spice_workspace.Path.rel change.Spice_tools.Receipt.path)
        ~op:(change_op change.Spice_tools.Receipt.op)
        ~before_target:change.Spice_tools.Receipt.before
        ~after_target:change.Spice_tools.Receipt.after ())
    (Spice_tools.Receipt.changes receipt)

let changes_of_result ~log ~session ~turn ~execution ?checkpoint result =
  match Spice_tool.Result.output result with
  | None -> Ok []
  | Some output -> (
      match Spice_tools.Evidence.mutation output with
      | None -> Ok []
      | Some evidence ->
          let call = Spice_session.Tool_claim.Started.call execution in
          let execution_id = Spice_session.Tool_claim.Started.id execution in
          let source =
            Spice_mutation.Change.Tool
              {
                execution = execution_id;
                call_id = Spice_llm.Tool.Call.id call;
                tool = Spice_llm.Tool.Call.name call;
              }
          in
          rows_of_receipt ~log ~session ~turn ~execution_id ~source ?checkpoint
            evidence)

let record_changes t ~session ~turn ~execution ?checkpoint result =
  let ( let* ) = Result.bind in
  let* changes =
    changes_of_result ~log:t.log ~session ~turn ~execution ?checkpoint result
  in
  match changes with
  | [] -> Ok []
  | changes ->
      let records =
        List.map (fun change -> Spice_mutation.Record.Change change) changes
      in
      let* () = append t ~session records in
      Ok changes

let turn_totals t ~session ~turn =
  let ( let* ) = Result.bind in
  let* records = read t ~session in
  Spice_mutation.changes records
  |> Spice_mutation.Scope.select (Spice_mutation.Scope.Turn turn)
  |> Spice_mutation.Change.totals |> Result.ok

(* The session-hook bridge: records workspace mutation evidence around
   executable tool calls without teaching the interpreter about mutations.
   Ledger or checkpoint failures degrade to events and never change the session
   transcript. The two exported entry points below are the callbacks a session
   hook installs; the interpreter wiring composes them. *)

let degrade observe message =
  observe (Spice_protocol.Event.Workspace_degraded { message })

let session_id document =
  Spice_session.id (Spice_session_store.Document.session document)

(* Lazy run checkpoint: captured before the first potentially mutating tool of a
   turn, at most once. The deterministic checkpoint id makes the once-per-turn
   check durable across continuation processes. *)
let ensure_run_checkpoint recorder ~observe document execution =
  let call = Spice_session.Tool_claim.Started.call execution in
  if not (Spice_tools.mutating_tool (Spice_llm.Tool.Call.name call)) then None
  else
    let session = session_id document in
    let turn = Spice_session.Tool_claim.Started.turn execution in
    match read recorder ~session with
    | Error message ->
        degrade observe ("mutation ledger read failed: " ^ message);
        None
    | Ok records -> (
        let id =
          Spice_mutation.Checkpoint.derive_id ~session ~turn
            ~reason:Spice_mutation.Checkpoint.Before_mutation
        in
        match Spice_mutation.find_checkpoint records id with
        | Some fact -> Some fact
        | None -> (
            match
              record_checkpoint recorder ~session ~turn
                ~reason:Spice_mutation.Checkpoint.Before_mutation
            with
            | Ok fact -> fact
            | Error message ->
                degrade observe ("checkpoint append failed: " ^ message);
                None))

(* Evidence rows append after the tool effect and before the durable finished
   event: a crash in that window leaves a waiting unfinished claim whose
   mutations are already recorded. *)
let record_workspace_changes recorder ~observe document execution checkpoint
    result =
  let session = session_id document in
  let turn = Spice_session.Tool_claim.Started.turn execution in
  let checkpoint_id =
    Option.bind checkpoint Spice_mutation.Checkpoint.available_id
  in
  match
    record_changes recorder ~session ~turn ~execution ?checkpoint:checkpoint_id
      result
  with
  | Error message ->
      degrade observe ("mutation evidence derivation failed: " ^ message)
  | Ok [] -> ()
  | Ok rows ->
      let total =
        match turn_totals recorder ~session ~turn with
        | Ok total -> total
        | Error _ -> Spice_mutation.Change.totals rows
      in
      observe
        (Spice_protocol.Event.Workspace_changed
           { claim = execution; checkpoint; changes = rows; total })

let around_tool recorder ~observe document execution finish_previous =
  let checkpoint = ensure_run_checkpoint recorder ~observe document execution in
  fun result ->
    finish_previous result;
    record_workspace_changes recorder ~observe document execution checkpoint
      result

(* End-of-run checkpoint: bounds shell attribution to the run window. Only
   captured when shell ran under an available start checkpoint, at most once per
   turn. *)
let run_end recorder ~observe document turn =
  if not (has_checkpoint_backend recorder) then ()
  else
    let session_doc = Spice_session_store.Document.session document in
    let session = Spice_session.id session_doc in
    let shell_ran =
      List.exists
        (fun (started, _) ->
          Spice_session.Turn.Id.equal
            (Spice_session.Tool_claim.Started.turn started)
            turn
          && String.equal
               (Spice_llm.Tool.Call.name
                  (Spice_session.Tool_claim.Started.call started))
               "shell")
        (Spice_session.State.tool_claims (Spice_session.state session_doc))
    in
    if not shell_ran then ()
    else
      match read recorder ~session with
      | Error message ->
          degrade observe ("mutation ledger read failed: " ^ message)
      | Ok records -> (
          let start_id =
            Spice_mutation.Checkpoint.derive_id ~session ~turn
              ~reason:Spice_mutation.Checkpoint.Before_mutation
          in
          let run_end_id =
            Spice_mutation.Checkpoint.derive_id ~session ~turn
              ~reason:Spice_mutation.Checkpoint.Run_end
          in
          let start_available =
            match Spice_mutation.find_checkpoint records start_id with
            | None -> false
            | Some fact ->
                Option.is_some (Spice_mutation.Checkpoint.available_id fact)
          in
          if
            (not start_available)
            || Option.is_some
                 (Spice_mutation.find_checkpoint records run_end_id)
          then ()
          else
            match
              record_checkpoint recorder ~session ~turn
                ~reason:Spice_mutation.Checkpoint.Run_end
            with
            | Ok _ -> ()
            | Error message ->
                degrade observe ("run-end checkpoint append failed: " ^ message)
          )

(* The two recording actions above, composed as a session hook. Both take the
   observer the interpreter supplies at fire time — not one captured here — so
   recording reaches the runner's final observer no matter where this hook sits
   in the composition (the consumer's observer is often installed after it).
   Around-tool records per-call change rows; the terminal turn outcome triggers
   the end-of-run checkpoint. *)
let hook recorder hooks =
  hooks
  |> Session.with_around_tool (around_tool recorder)
  |> Session.with_terminal_observed (fun ~observe (document, outcome) ->
      match (outcome : Spice_protocol.Outcome.t) with
      | Spice_protocol.Outcome.Waiting _ -> ()
      | Spice_protocol.Outcome.Finished { turn; _ } ->
          run_end recorder ~observe document turn)
