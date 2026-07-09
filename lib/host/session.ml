(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

(* This module re-exposes the interpreter's hooks surface abstractly and adds the
   standalone housekeeping ({!store}, {!create}, {!listing}, {!compact},
   {!generate_title}) that plans no tool steps and needs no runner. Execution
   itself is reached only through {!Runner.execute}. *)

type request_preparation = Session_loop.request_preparation = {
  request : Spice_llm.Request.t;
  commit : unit -> unit;
  rollback : unit -> unit;
}

type hooks = Session_loop.hooks

(* The combinators delegate to {!Session_loop}: [hooks] is abstract here, so
   values are built and observed through the private core. *)
let no_hooks = Session_loop.no_hooks

let with_prepare_request prepare hooks =
  Session_loop.with_prepare_request prepare hooks

let with_after_save after_save hooks =
  Session_loop.with_after_save after_save hooks

let after_save hooks document events =
  Session_loop.after_save hooks document events

let with_around_tool around hooks = Session_loop.with_around_tool around hooks
let with_observe observe hooks = Session_loop.with_observe observe hooks
let observe hooks event = Session_loop.observe hooks event

let with_terminal_observed terminal hooks =
  Session_loop.with_terminal_observed terminal hooks

let with_cancelled cancelled hooks = Session_loop.with_cancelled cancelled hooks

let with_notices ?before_request queue hooks =
  Session_loop.with_notices ?before_request queue hooks

(* UTF-8-safe text normalization for titles and prompt previews. The host [Text]
   module the old surface exposed is gone; these two helpers are inlined so this
   module carries no dependency beyond the session vocabulary, mirroring the
   normalization the protocol summary projection uses. *)

let is_space = function ' ' | '\n' | '\r' | '\t' | '\012' -> true | _ -> false

let collapse_whitespace text =
  let len = String.length text in
  let buffer = Buffer.create len in
  let rec skip_spaces index =
    if index < len && is_space text.[index] then skip_spaces (index + 1)
    else index
  in
  let rec loop index pending_space =
    if index >= len then ()
    else if is_space text.[index] then loop (skip_spaces index) true
    else begin
      if pending_space && Buffer.length buffer > 0 then
        Buffer.add_char buffer ' ';
      Buffer.add_char buffer text.[index];
      loop (index + 1) false
    end
  in
  loop (skip_spaces 0) false;
  Buffer.contents buffer

let utf8_boundary text index =
  let rec loop index =
    if index <= 0 then 0
    else
      let code = Char.code text.[index] in
      if code land 0b1100_0000 = 0b1000_0000 then loop (index - 1) else index
  in
  loop (min index (String.length text))

let truncate ~max_bytes text =
  if String.length text <= max_bytes then text
  else String.sub text 0 (utf8_boundary text max_bytes)

module Title = struct
  let instruction ~prompt =
    "Generate a concise 3-5 word title for this coding session. Return only \
     the title, with no quotes or punctuation.\n\n\
     Prompt:\n" ^ prompt

  let normalize raw =
    let raw =
      String.split_on_char '\n' raw
      |> String.concat " " |> String.trim |> collapse_whitespace
    in
    if String.is_empty raw then None
    else
      let title = String.trim (truncate ~max_bytes:60 raw) in
      if String.is_empty title then None else Some title
end

let store ~stdenv host =
  Spice_session_store.make ~fs:(Eio.Stdenv.fs stdenv)
    ~clock:(Eio.Stdenv.clock stdenv)
    ~root:(Config.data_home (Host.config host))

let store_error = Session_loop.of_store

let load store id =
  Spice_session_store.load store id |> Result.map_error Session_loop.of_store

let save store document session =
  Spice_session_store.save store document session
  |> Result.map_error Session_loop.of_store

let fresh_counter = ref 0

let fresh_id ~clock prefix =
  incr fresh_counter;
  let stamp = Eio.Time.now clock |> Int64.bits_of_float |> Int64.to_string in
  prefix ^ "_" ^ stamp ^ "_" ^ string_of_int !fresh_counter

let fresh_session_id ~clock = Spice_session.Id.of_string (fresh_id ~clock "ses")

let fresh_turn_id ~clock =
  Spice_session.Turn.Id.of_string (fresh_id ~clock "turn")

let create ~store ~id ?title ~cwd ~created_at () =
  let session = Spice_session.create ~id ?title ~cwd ~created_at () in
  Spice_session_store.create store session
  |> Result.map_error Session_loop.of_store

(* Flatten a pure session error into the host's single protocol error, following
   the same recovery-class grouping the store path uses: idle-guard violations
   map to their protocol siblings; anchor-resolution and replay invariants a
   host cannot repair become {!Internal}. Callers surface the anchor cases as
   recoverable input by previewing with {!Spice_session.dropped_turns} first. *)
let session_error ~id (error : Spice_session.Error.t) : Spice_protocol.Error.t =
  match error with
  | Spice_session.Error.Archived -> Spice_protocol.Error.Archived id
  | Spice_session.Error.Deleted -> Spice_protocol.Error.Deleted id
  | Spice_session.Error.Active_turn turn ->
      Spice_protocol.Error.Active_turn_exists turn
  | Spice_session.Error.State _ | Spice_session.Error.Unknown_turn _
  | Spice_session.Error.Turn_not_finished _ ->
      Spice_protocol.Error.Internal (Spice_session.Error.message error)

let fork_attempts = 3

let fork ~store ~clock ?id ?title ~cwd document =
  let parent = Spice_session_store.Document.session document in
  let created_at =
    Eio.Time.now clock |> Spice_session.Time.of_unix_seconds_float
  in
  let fork_session id =
    Spice_session.fork ~id ?title ~cwd ~created_at parent
    |> Result.map_error (session_error ~id:(Spice_session.id parent))
  in
  match id with
  | Some id ->
      (* An explicit id that collides is the caller's error, not a retry. *)
      let* child = fork_session id in
      Spice_session_store.create store child
      |> Result.map_error Session_loop.of_store
  | None ->
      let rec attempt remaining =
        let id = fresh_session_id ~clock in
        let* child = fork_session id in
        match Spice_session_store.create store child with
        | Ok _ as created -> created
        | Error (Spice_session_store.Error.Already_exists _) when remaining > 1
          ->
            attempt (remaining - 1)
        | Error (Spice_session_store.Error.Already_exists _) ->
            Error
              (Spice_protocol.Error.Internal
                 ("generated child session id already exists after "
                 ^ string_of_int fork_attempts
                 ^ " attempts"))
        | Error error -> Error (Session_loop.of_store error)
      in
      attempt fork_attempts

let rewind ~store ~id ?title ~cwd ~created_at anchor document =
  let parent = Spice_session_store.Document.session document in
  let* child =
    Spice_session.rewind ~id ?title ~cwd ~created_at anchor parent
    |> Result.map_error (session_error ~id:(Spice_session.id parent))
  in
  Spice_session_store.create store child
  |> Result.map_error Session_loop.of_store

type listing = {
  rows : Spice_protocol.Session_summary.t list;
  warnings : string list;
}

let of_document document =
  Spice_protocol.Session_summary.of_session
    ~revision:(Spice_session_store.Document.revision document)
    (Spice_session_store.Document.session document)

let first_line text =
  match String.split_on_char '\n' text with [] -> text | line :: _ -> line

let corrupt_warning corrupt =
  Spice_session_store.Corrupt.path corrupt
  ^ ": "
  ^ first_line (Spice_session_store.Corrupt.message corrupt)

let listing ~documents ~corrupt =
  {
    rows = List.map of_document documents;
    warnings = List.map corrupt_warning corrupt;
  }

let in_cwd cwd document =
  Spice_path.Abs.equal cwd
    (Spice_session.Metadata.cwd
       (Spice_session.metadata (Spice_session_store.Document.session document)))

let newest_in_cwd store ~cwd =
  match Spice_session_store.list store ~filter:(in_cwd cwd) ~limit:1 () with
  | Error error -> Error (store_error error)
  | Ok (documents, corrupt) ->
      let summary =
        match documents with
        | document :: _ -> Some (of_document document)
        | [] -> None
      in
      Ok (summary, corrupt)

let recent_in_cwd store ~fs ~cwd ~limit =
  (* Subagent child sessions live in the store like any other, so exclude them
     the way the session picker does — one filename-only membership scan, no run
     file decoded — before the limit, so a family of subagents never crowds the
     top-level sessions out of the list. *)
  let children =
    match
      Artifacts.Subagent_run.children ~fs
        ~root:(Spice_session_store.root store |> Spice_path.Abs.to_string)
    with
    | Ok ids -> ids
    | Error _ -> []
  in
  let top_level document =
    let id = Spice_session.id (Spice_session_store.Document.session document) in
    in_cwd cwd document
    && not (List.exists (Spice_session.Id.equal id) children)
  in
  match Spice_session_store.list store ~filter:top_level ~limit () with
  | Error error -> Error (store_error error)
  | Ok (documents, corrupt) -> Ok (List.map of_document documents, corrupt)

module Threads = struct
  type source =
    | Main
    | Fork of { parent : Spice_session.Id.t }
    | Subagent of {
        parent : Spice_session.Id.t;
        role : Spice_protocol.Subagent.Role.t;
        status : Spice_protocol.Subagent_run.Status.t;
      }

  type entry = { summary : Spice_protocol.Session_summary.t; source : source }

  let of_store ~fs ~store ~current =
    let* documents, corrupt =
      Spice_session_store.list store ()
      |> Result.map_error Session_loop.of_store
    in
    let summaries = List.map of_document documents in
    let by_id = Hashtbl.create (List.length summaries) in
    List.iter
      (fun summary ->
        Hashtbl.replace by_id
          (Spice_session.Id.to_string summary.Spice_protocol.Session_summary.id)
          summary)
      summaries;
    let children = Hashtbl.create (List.length summaries) in
    let parent_of = Hashtbl.create (List.length summaries) in
    let has_summary id = Hashtbl.mem by_id (Spice_session.Id.to_string id) in
    (* Only relations whose both ends have a summary are linked; the first
       recorded parent wins, so lineage stays a forest. *)
    let add_child ~parent ~child ~source ~created_at =
      if has_summary parent && has_summary child then (
        let parent_key = Spice_session.Id.to_string parent in
        let child_key = Spice_session.Id.to_string child in
        let existing =
          Option.value (Hashtbl.find_opt children parent_key) ~default:[]
        in
        if
          not
            (List.exists
               (fun (existing_child, _, _) ->
                 Spice_session.Id.equal child existing_child)
               existing)
        then
          Hashtbl.replace children parent_key
            ((child, source, created_at) :: existing);
        if not (Hashtbl.mem parent_of child_key) then
          Hashtbl.replace parent_of child_key parent)
    in
    List.iter
      (fun summary ->
        match summary.Spice_protocol.Session_summary.forked_from with
        | None -> ()
        | Some forked_from ->
            let parent =
              Spice_session.Metadata.Forked_from.parent forked_from
            in
            let child = summary.Spice_protocol.Session_summary.id in
            add_child ~parent ~child
              ~source:(Fork { parent })
              ~created_at:summary.Spice_protocol.Session_summary.created_at)
      summaries;
    let root = Spice_session_store.root store |> Spice_path.Abs.to_string in
    let subagent_warnings = ref [] in
    List.iter
      (fun summary ->
        let parent = summary.Spice_protocol.Session_summary.id in
        match Artifacts.Subagent_run.list ~fs ~root ~parent with
        | Ok runs ->
            List.iter
              (fun run ->
                let child = Spice_protocol.Subagent_run.child run in
                add_child ~parent ~child
                  ~source:
                    (Subagent
                       {
                         parent;
                         role = Spice_protocol.Subagent_run.role run;
                         status = Spice_protocol.Subagent_run.status run;
                       })
                  ~created_at:(Spice_protocol.Subagent_run.created_at run))
              runs
        | Error error ->
            subagent_warnings :=
              ("subagents for "
              ^ Spice_session.Id.to_string parent
              ^ ": "
              ^ Artifacts.Error.message error)
              :: !subagent_warnings)
      summaries;
    let warnings =
      List.map corrupt_warning corrupt @ List.rev !subagent_warnings
    in
    if not (Hashtbl.mem by_id (Spice_session.Id.to_string current)) then
      Ok ([], warnings)
    else
      (* Walk to the family root, cutting lineage cycles at the revisit. *)
      let rec root_of visited session =
        let key = Spice_session.Id.to_string session in
        if List.mem key visited then session
        else
          match Hashtbl.find_opt parent_of key with
          | Some parent when has_summary parent ->
              root_of (key :: visited) parent
          | Some _ | None -> session
      in
      let compare_child (a, _, a_created) (b, _, b_created) =
        match Spice_session.Time.compare a_created b_created with
        | 0 -> Spice_session.Id.compare a b
        | order -> order
      in
      let rec rows_for session source =
        let key = Spice_session.Id.to_string session in
        let summary = Hashtbl.find by_id key in
        let child_rows =
          Option.value (Hashtbl.find_opt children key) ~default:[]
          |> List.sort compare_child
          |> List.concat_map (fun (child, source, _) -> rows_for child source)
        in
        { summary; source } :: child_rows
      in
      Ok (rows_for (root_of [] current) Main, warnings)
end

let save_title ~store ~title document =
  let session =
    Spice_session.set_title (Some title)
      (Spice_session_store.Document.session document)
  in
  save store document session

(* Each lifecycle verb pairs a pure {!Spice_session} mutation with the store save
   the caller would otherwise repeat, mirroring {!save_title}: the mutation's
   idle-guard refusals (an active turn, a deleted target) flatten through
   {!session_error} to their protocol siblings, and the save flattens through
   {!save}. The non-attached path — an attached session routes through
   {!Live.write}. *)
let lifecycle mutate ~store document =
  let session = Spice_session_store.Document.session document in
  match
    mutate session
    |> Result.map_error (session_error ~id:(Spice_session.id session))
  with
  | Error _ as error -> error
  | Ok session -> save store document session

let delete ~store document = lifecycle Spice_session.delete ~store document
let archive ~store document = lifecycle Spice_session.archive ~store document
let restore ~store document = lifecycle Spice_session.restore ~store document

let first_user_prompt session =
  Spice_session.State.turns (Spice_session.state session)
  |> List.find_map (fun turn ->
      match
        Spice_session.Turn.input turn
        |> Spice_session.Turn.Input.text
        |> Option.map collapse_whitespace
      with
      | None | Some "" -> None
      | Some text -> Some text)

let title_for ~client ?cancelled ~model document =
  let session = Spice_session_store.Document.session document in
  match Spice_session.Metadata.title (Spice_session.metadata session) with
  | Some _ -> Ok None
  | None -> (
      match first_user_prompt session with
      | None -> Ok None
      | Some prompt ->
          let* transcript =
            Spice_llm.Transcript.of_list
              [ Spice_llm.Message.user_text (Title.instruction ~prompt) ]
            |> Result.map_error (fun error ->
                Spice_protocol.Error.Internal
                  (Spice_llm.Transcript.Error.message error))
          in
          let options =
            Spice_llm.Request.Options.make
              ~tool_choice:Spice_llm.Request.Options.No_tools
              ~max_output_tokens:32 ()
          in
          let* request =
            Spice_llm.Request.make ~model ~options transcript
            |> Result.map_error (fun error ->
                Spice_protocol.Error.Internal
                  (Spice_llm.Request.Error.message error))
          in
          let* response =
            Spice_llm.Client.response ?cancelled client request
            |> Result.map_error (fun error ->
                Spice_protocol.Error.Provider error)
          in
          Ok (Title.normalize (Spice_llm.Response.text ~sep:" " response)))

let generate_title ~store ~client ?cancelled ~model document =
  match title_for ~client ?cancelled ~model document with
  | Error _ as error -> error
  | Ok None -> Ok document
  | Ok (Some title) -> save_title ~store ~title document

let compact ~store ~client ?(policy = Compactor.Policy.default)
    ?(observe = Session_loop.no_observe)
    ?(after_save = Session_loop.no_after_save) document =
  (* Explicit host-requested compaction requires an idle session and is by
     definition user-requested. Automatic compaction during execution goes
     through {!Compaction_run.compact_with} directly and may run while the
     active turn is request-ready. *)
  let session = Spice_session_store.Document.session document in
  let* () = Session_loop.check_active_document session in
  let* () = Session_loop.require_no_active_turn session in
  let save document events = Session_loop.raw_save store document events in
  let model ~cancelled request =
    Spice_llm.Client.response ~cancelled client request
  in
  Compaction_run.compact_with ~save ~model ~policy ~observe ~after_save
    ~cancelled:Session_loop.not_cancelled document
    ~reason:Spice_session.Compaction.Reason.User_requested
  |> Result.map_error Session_loop.of_compaction
