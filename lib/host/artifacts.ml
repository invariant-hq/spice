(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Result.Syntax

module Error = struct
  type t =
    | Not_found of { kind : string; key : string }
    | Conflict of { kind : string; key : string }
    | Corrupt_file of { path : string; message : string }
    | Io of { path : string; message : string }

  let message (error : t) =
    match error with
    | Not_found { kind; key } -> kind ^ " not found: " ^ key
    | Conflict { kind; key } -> kind ^ " conflict: " ^ key
    | Corrupt_file { path; message } -> path ^ ": " ^ message
    | Io { path; message } -> path ^ ": " ^ message

  let diagnostic error = Spice_diagnostic.make (message error)
  let pp ppf t = Format.pp_print_string ppf (message t)

  (* A corrupt file or filesystem error is an execution [Storage] failure; a
     not-found or conflict is a lower-layer invariant the caller cannot repair
     mid-turn, so it surfaces as [Internal] carrying [message]. *)
  let to_protocol_error (error : t) : Spice_protocol.Error.t =
    match error with
    | Corrupt_file { path; message } | Io { path; message } ->
        Spice_protocol.Error.Storage { path; message }
    | (Not_found _ | Conflict _) as error ->
        Spice_protocol.Error.Internal (message error)
end

(* Keys become file names through conservative percent-escaping so ids remain
   readable while arbitrary strings stay one-file-per-key. This matches the byte
   layout the sidecar wrote, so existing artifact files stay readable. *)
let hex = "0123456789ABCDEF"

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let escaped_component text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (fun c ->
      if is_unreserved c then Buffer.add_char buffer c
      else begin
        let code = Char.code c in
        Buffer.add_char buffer '%';
        Buffer.add_char buffer hex.[code lsr 4];
        Buffer.add_char buffer hex.[code land 0x0f]
      end)
    text;
  Buffer.contents buffer

let hex_value = function
  | '0' .. '9' as c -> Some (Char.code c - Char.code '0')
  | 'A' .. 'F' as c -> Some (10 + Char.code c - Char.code 'A')
  | 'a' .. 'f' as c -> Some (10 + Char.code c - Char.code 'a')
  | _ -> None

let unescaped_component path text =
  let invalid message = Error (Error.Corrupt_file { path; message }) in
  let buffer = Buffer.create (String.length text) in
  let rec decode index =
    if index = String.length text then Ok (Buffer.contents buffer)
    else
      match text.[index] with
      | '%' ->
          if index + 2 >= String.length text then
            invalid "truncated percent escape in artifact filename"
          else (
            match (hex_value text.[index + 1], hex_value text.[index + 2]) with
            | Some high, Some low ->
                Buffer.add_char buffer (Char.chr ((high lsl 4) lor low));
                decode (index + 3)
            | _ -> invalid "invalid percent escape in artifact filename")
      | c when is_unreserved c ->
          Buffer.add_char buffer c;
          decode (index + 1)
      | _ -> invalid "unescaped reserved byte in artifact filename"
  in
  decode 0

let fs_path ~fs p = Eio.Path.( / ) fs p

let io p f =
  match f () with
  | value -> Ok value
  | exception exn ->
      Error (Error.Io { path = p; message = Printexc.to_string exn })

let mkdir_p ~fs dir =
  io dir (fun () ->
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 (fs_path ~fs dir))

let file_exists ~fs p = Eio.Path.is_file (fs_path ~fs p)
let dir_exists ~fs p = Eio.Path.is_directory (fs_path ~fs p)

let encode codec p value =
  Jsont_bytesrw.encode_string codec value
  |> Result.map (fun text -> text ^ "\n")
  |> Result.map_error (fun message -> Error.Corrupt_file { path = p; message })

let decode codec p text =
  Jsont_bytesrw.decode_string codec text
  |> Result.map_error (fun message -> Error.Corrupt_file { path = p; message })

let write_file ~fs ~create codec p value =
  let* text = encode codec p value in
  let* () = mkdir_p ~fs (Filename.dirname p) in
  io p (fun () -> Eio.Path.save ~create (fs_path ~fs p) text)

let tmp_counter = ref 0

let tmp_path p =
  incr tmp_counter;
  p ^ ".tmp."
  ^ string_of_int (Unix.getpid ())
  ^ "." ^ string_of_int !tmp_counter

let remove_file ~fs p =
  if file_exists ~fs p then io p (fun () -> Eio.Path.unlink (fs_path ~fs p))
  else Ok ()

let save_file ~fs codec p value =
  let* text = encode codec p value in
  let* () = mkdir_p ~fs (Filename.dirname p) in
  let tmp = tmp_path p in
  let* () =
    io tmp (fun () ->
        Eio.Path.save ~create:(`Exclusive 0o600) (fs_path ~fs tmp) text)
  in
  match io p (fun () -> Eio.Path.rename (fs_path ~fs tmp) (fs_path ~fs p)) with
  | Ok () -> Ok ()
  | Error error -> (
      match remove_file ~fs tmp with
      | Ok () -> Error error
      | Error cleanup ->
          Error
            (Error.Io
               {
                 path = p;
                 message =
                   Error.message error ^ "; temporary-file cleanup failed: "
                   ^ Error.message cleanup;
               }))

let create_file ~fs ~kind ~key codec p value =
  if file_exists ~fs p then Error (Error.Conflict { kind; key })
  else write_file ~fs ~create:(`Exclusive 0o600) codec p value

let read_file ~fs codec p =
  if not (file_exists ~fs p) then Ok None
  else
    let* text = io p (fun () -> Eio.Path.load (fs_path ~fs p)) in
    let* value = decode codec p text in
    Ok (Some value)

let is_json_file name = String.equal (Filename.extension name) ".json"

let list_dir ~fs codec dir =
  if not (dir_exists ~fs dir) then Ok []
  else
    let* names = io dir (fun () -> Eio.Path.read_dir (fs_path ~fs dir)) in
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | name :: names ->
          if not (is_json_file name) then collect acc names
          else
            let p = Filename.concat dir name in
            if not (file_exists ~fs p) then collect acc names
            else
              let* text = io p (fun () -> Eio.Path.load (fs_path ~fs p)) in
              let* value = decode codec p text in
              collect (value :: acc) names
    in
    collect [] (List.sort String.compare names)

module Plan = struct
  let kind = "plan"
  let dir ~root = Filename.concat root "plans"

  let reject_unscoped_files ~fs ~root =
    let base = dir ~root in
    if not (dir_exists ~fs base) then Ok ()
    else
      let* names = io base (fun () -> Eio.Path.read_dir (fs_path ~fs base)) in
      match List.find_opt is_json_file names with
      | None -> Ok ()
      | Some name ->
          let path = Filename.concat base name in
          Error
            (Error.Corrupt_file
               {
                 path;
                 message =
                   "unscoped plan artifacts are unsupported; expected \
                    plans/<session>/<plan>.json";
               })

  let session_dir ~root session =
    Filename.concat (dir ~root)
      (escaped_component (Spice_session.Id.to_string session))

  let path ~root ~session id =
    Filename.concat
      (session_dir ~root session)
      (escaped_component (Spice_protocol.Plan.Id.to_string id) ^ ".json")

  let plan_session plan =
    Spice_protocol.Plan.Source.session (Spice_protocol.Plan.source plan)

  let save ~fs ~root plan =
    let* () = reject_unscoped_files ~fs ~root in
    let session = plan_session plan in
    save_file ~fs Spice_protocol.Plan.jsont
      (path ~root ~session (Spice_protocol.Plan.id plan))
      plan

  let create ~fs ~root plan =
    let* () = reject_unscoped_files ~fs ~root in
    let id = Spice_protocol.Plan.id plan in
    let session = plan_session plan in
    create_file ~fs ~kind
      ~key:
        (Spice_session.Id.to_string session
        ^ "/"
        ^ Spice_protocol.Plan.Id.to_string id)
      Spice_protocol.Plan.jsont (path ~root ~session id) plan

  let load ~fs ~root ~session id =
    let* () = reject_unscoped_files ~fs ~root in
    let key = Spice_protocol.Plan.Id.to_string id in
    let p = path ~root ~session id in
    let* plan = read_file ~fs Spice_protocol.Plan.jsont p in
    match plan with
    | None -> Error (Error.Not_found { kind; key })
    | Some plan ->
        let stored = Spice_protocol.Plan.id plan in
        let stored_session = plan_session plan in
        if
          Spice_protocol.Plan.Id.equal stored id
          && Spice_session.Id.equal stored_session session
        then Ok plan
        else
          Error
            (Error.Corrupt_file
               {
                 path = p;
                 message =
                   Printf.sprintf
                     "plan key %S/%S does not match requested key %S/%S"
                     (Spice_session.Id.to_string stored_session)
                     (Spice_protocol.Plan.Id.to_string stored)
                     (Spice_session.Id.to_string session)
                     key;
               })

  let compare_newest a b =
    match
      Spice_session.Time.compare
        (Spice_protocol.Plan.updated_at b)
        (Spice_protocol.Plan.updated_at a)
    with
    | 0 ->
        Spice_protocol.Plan.Id.compare (Spice_protocol.Plan.id a)
          (Spice_protocol.Plan.id b)
    | order -> order

  let list ~fs ~root ~session =
    let* () = reject_unscoped_files ~fs ~root in
    let* plans =
      list_dir ~fs Spice_protocol.Plan.jsont (session_dir ~root session)
    in
    let rec check acc = function
      | [] -> Ok (List.sort compare_newest acc)
      | plan :: rest ->
          if Spice_session.Id.equal (plan_session plan) session then
            check (plan :: acc) rest
          else
            let p = path ~root ~session (Spice_protocol.Plan.id plan) in
            Error
              (Error.Corrupt_file
                 {
                   path = p;
                   message =
                     Printf.sprintf
                       "plan session %S does not match requested key %S"
                       (Spice_session.Id.to_string (plan_session plan))
                       (Spice_session.Id.to_string session);
                 })
    in
    check [] plans

  type proposal_result = Stored | Refused of string

  let proposal_conflict session id =
    Error.Conflict
      {
        kind;
        key =
          Spice_session.Id.to_string session
          ^ "/"
          ^ Spice_protocol.Plan.Id.to_string id;
      }

  let rollback_replacement ~fs ~root ~created originals =
    let rec restore first_error = function
      | [] -> first_error
      | plan :: rest -> (
          match save ~fs ~root plan with
          | Ok () -> restore first_error rest
          | Error error ->
              let first_error =
                match first_error with
                | Some _ -> first_error
                | None -> Some error
              in
              restore first_error rest)
    in
    let restore_error = restore None originals in
    let remove_error =
      match
        remove_file ~fs
          (path ~root ~session:(plan_session created)
             (Spice_protocol.Plan.id created))
      with
      | Ok () -> None
      | Error error -> Some error
    in
    match (restore_error, remove_error) with
    | None, None -> Ok ()
    | Some error, None | None, Some error -> Error error
    | Some restore, Some remove ->
        Error
          (Error.Io
             {
               path = dir ~root;
               message =
                 "plan replacement rollback failed: " ^ Error.message restore
                 ^ "; replacement cleanup failed: " ^ Error.message remove;
             })

  let commit_replacement ~fs ~root plan updates =
    match create ~fs ~root plan with
    | Error (Error.Conflict _ as error) -> Ok (Refused (Error.message error))
    | Error error -> Error error
    | Ok () ->
        let rec save_updates originals = function
          | [] -> Ok Stored
          | (original, updated) :: rest -> (
              match save ~fs ~root updated with
              | Ok () -> save_updates (original :: originals) rest
              | Error write_error -> (
                  match
                    rollback_replacement ~fs ~root ~created:plan originals
                  with
                  | Ok () -> Error write_error
                  | Error rollback_error ->
                      Error
                        (Error.Io
                           {
                             path = dir ~root;
                             message =
                               "plan replacement failed: "
                               ^ Error.message write_error ^ "; "
                               ^ Error.message rollback_error;
                           })))
        in
        save_updates [] updates

  let propose ~fs ~root ~superseded_at plan =
    let session = plan_session plan in
    let id = Spice_protocol.Plan.id plan in
    let* plans = list ~fs ~root ~session in
    if
      List.exists
        (fun stored ->
          Spice_protocol.Plan.Id.equal (Spice_protocol.Plan.id stored) id)
        plans
    then Ok (Refused (Error.message (proposal_conflict session id)))
    else
      let supersedable stored =
        let status = Spice_protocol.Plan.status stored in
        Spice_protocol.Plan.Status.is_proposed status
        || Spice_protocol.Plan.Status.is_approved status
      in
      let rec updates acc = function
        | [] -> Ok (List.rev acc)
        | stored :: rest -> (
            if not (supersedable stored) then updates acc rest
            else
              match
                Spice_protocol.Plan.supersede ~superseded_at ~by:id stored
              with
              | Error message -> Error message
              | Ok updated -> updates ((stored, updated) :: acc) rest)
      in
      match updates [] plans with
      | Error message -> Ok (Refused message)
      | Ok updates -> commit_replacement ~fs ~root plan updates

  let resolve ~fs ~root ~session ~now ~decision proposal =
    let id = Spice_protocol.Plan.Proposal.id proposal in
    let* plan = load ~fs ~root ~session id in
    let transitioned =
      match (decision : Spice_protocol.Plan.Decision.t) with
      | Spice_protocol.Plan.Decision.Approve ->
          Spice_protocol.Plan.approve ~approved_at:now plan
      | Spice_protocol.Plan.Decision.Reject { reason } ->
          Spice_protocol.Plan.reject ~rejected_at:now ?reason plan
    in
    match transitioned with
    | Error (_ : string) ->
        (* The stored plan is not in the state the decision expects — a state
           race, not a corrupt store; callers reload and re-inspect. *)
        Error
          (Error.Conflict { kind; key = Spice_protocol.Plan.Id.to_string id })
    | Ok plan ->
        let* () = save ~fs ~root plan in
        let id = Spice_protocol.Plan.Id.to_string id in
        let text =
          match (decision : Spice_protocol.Plan.Decision.t) with
          | Spice_protocol.Plan.Decision.Approve ->
              "Plan approved: " ^ id ^ ". Proceed with the plan."
          | Spice_protocol.Plan.Decision.Reject { reason = None } ->
              "Plan rejected: " ^ id ^ ". Revise the plan before proceeding."
          | Spice_protocol.Plan.Decision.Reject { reason = Some reason } ->
              "Plan rejected: " ^ id ^ ". Reason: " ^ reason
        in
        Ok text
end

module Todo = struct
  let dir ~root = Filename.concat root "todos"

  let path ~root session =
    Filename.concat (dir ~root)
      (escaped_component (Spice_session.Id.to_string session) ^ ".json")

  let save ~fs ~root ~session todos =
    save_file ~fs Spice_protocol.Todo.jsont (path ~root session) todos

  let load ~fs ~root session =
    let* todos = read_file ~fs Spice_protocol.Todo.jsont (path ~root session) in
    Ok (Option.value todos ~default:Spice_protocol.Todo.empty)
end

module Goal = struct
  let dir ~root = Filename.concat root "goals"

  let path ~root session =
    Filename.concat (dir ~root)
      (escaped_component (Spice_session.Id.to_string session) ^ ".json")

  let save ~fs ~root goal =
    save_file ~fs Spice_protocol.Goal.jsont
      (path ~root (Spice_protocol.Goal.session goal))
      goal

  let load ~fs ~root session =
    let p = path ~root session in
    let* goal = read_file ~fs Spice_protocol.Goal.jsont p in
    match goal with
    | None -> Ok None
    | Some goal ->
        let stored = Spice_protocol.Goal.session goal in
        if Spice_session.Id.equal stored session then Ok (Some goal)
        else
          Error
            (Error.Corrupt_file
               {
                 path = p;
                 message =
                   Printf.sprintf
                     "goal session %S does not match requested key %S"
                     (Spice_session.Id.to_string stored)
                     (Spice_session.Id.to_string session);
               })

  type update_result = Updated of string | Refused of string

  let usage_suffix goal =
    match Spice_protocol.Goal.token_budget goal with
    | None -> ""
    | Some budget ->
        Printf.sprintf " Final token usage: %d of %d."
          (Spice_protocol.Goal.tokens_used goal)
          budget

  let update ~fs ~root ~now ~session update =
    let* goal = load ~fs ~root session in
    match goal with
    | None ->
        Ok
          (Refused
             ("no goal is set for session "
             ^ Spice_session.Id.to_string session
             ^ "; update_goal is unavailable"))
    | Some goal -> (
        match Spice_protocol.Goal.apply ~now update goal with
        (* The stored goal does not admit the report — a state race with a user
           lifecycle verb, answered to the model, never parked. *)
        | Error message -> Ok (Refused message)
        | Ok goal ->
            let* () = save ~fs ~root goal in
            let id =
              Spice_protocol.Goal.Id.to_string (Spice_protocol.Goal.id goal)
            in
            let text =
              match (update : Spice_protocol.Goal.Update.t) with
              | Spice_protocol.Goal.Update.Complete _ ->
                  "Goal completed: " ^ id ^ "." ^ usage_suffix goal
              | Spice_protocol.Goal.Update.Blocked _ ->
                  "Goal blocked: " ^ id ^ ". Waiting for the user."
            in
            Ok (Updated text))
end

module Subagent_run = struct
  let parent_dir ~root parent =
    Filename.concat
      (Filename.concat root "subagents")
      (escaped_component (Spice_session.Id.to_string parent))

  let child_path ~root ~parent ~child =
    Filename.concat (parent_dir ~root parent)
      (escaped_component (Spice_session.Id.to_string child) ^ ".json")

  let path_of ~root run =
    child_path ~root
      ~parent:(Spice_protocol.Subagent_run.parent run)
      ~child:(Spice_protocol.Subagent_run.child run)

  let compare_run a b =
    match
      Spice_session.Time.compare
        (Spice_protocol.Subagent_run.created_at a)
        (Spice_protocol.Subagent_run.created_at b)
    with
    | 0 ->
        Spice_session.Id.compare
          (Spice_protocol.Subagent_run.child a)
          (Spice_protocol.Subagent_run.child b)
    | order -> order

  let corrupt p message = Error (Error.Corrupt_file { path = p; message })

  let check_parent p ~parent run =
    let actual = Spice_protocol.Subagent_run.parent run in
    if Spice_session.Id.equal parent actual then Ok run
    else
      corrupt p
        ("subagent run parent mismatch: expected "
        ^ Spice_session.Id.to_string parent
        ^ ", got "
        ^ Spice_session.Id.to_string actual)

  let check_child p ~child run =
    let actual = Spice_protocol.Subagent_run.child run in
    if Spice_session.Id.equal child actual then Ok run
    else
      corrupt p
        ("subagent run child mismatch: expected "
        ^ Spice_session.Id.to_string child
        ^ ", got "
        ^ Spice_session.Id.to_string actual)

  let put ~fs ~root run =
    save_file ~fs Spice_protocol.Subagent_run.jsont (path_of ~root run) run

  let remove ~fs ~root run = remove_file ~fs (path_of ~root run)

  let load ~fs ~root ~parent ~child =
    let p = child_path ~root ~parent ~child in
    let* run = read_file ~fs Spice_protocol.Subagent_run.jsont p in
    match run with
    | None -> Ok None
    | Some run ->
        let* run = check_parent p ~parent run in
        let* run = check_child p ~child run in
        Ok (Some run)

  let list ~fs ~root ~parent =
    let* runs =
      list_dir ~fs Spice_protocol.Subagent_run.jsont (parent_dir ~root parent)
    in
    let rec check acc = function
      | [] -> Ok (List.rev acc)
      | run :: rest ->
          let p =
            child_path ~root ~parent
              ~child:(Spice_protocol.Subagent_run.child run)
          in
          let* run = check_parent p ~parent run in
          check (run :: acc) rest
    in
    let* runs = check [] runs in
    Ok (List.sort compare_run runs)

  (* Child ids across every parent, from filenames alone: no file is decoded,
     so one corrupt run cannot hide the rest from a caller that only needs
     the id set (the session picker's child filter). *)
  let children ~fs ~root =
    let base = Filename.concat root "subagents" in
    if not (dir_exists ~fs base) then Ok []
    else
      let* parents = io base (fun () -> Eio.Path.read_dir (fs_path ~fs base)) in
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | parent :: rest ->
            let dir = Filename.concat base parent in
            if not (dir_exists ~fs dir) then collect acc rest
            else
              let* names =
                io dir (fun () -> Eio.Path.read_dir (fs_path ~fs dir))
              in
              let rec decode_ids ids = function
                | [] -> Ok ids
                | name :: names ->
                    if not (is_json_file name) then decode_ids ids names
                    else
                      let path = Filename.concat dir name in
                      let* id =
                        unescaped_component path
                          (Filename.remove_extension name)
                      in
                      if String.is_empty id then
                        corrupt path "child session id must not be empty"
                      else
                        decode_ids
                          (Spice_session.Id.of_string id :: ids)
                          names
              in
              let* ids = decode_ids [] names in
              collect (List.rev_append ids acc) rest
      in
      collect [] parents
end
