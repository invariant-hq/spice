(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Rel = Spice_path.Rel

let decode_error message = Jsont.Error.msg Jsont.Meta.none message
let short_id prefix parts = prefix ^ ":" ^ Spice_digest.key ~length:16 parts

let rel_jsont =
  Jsont.map ~kind:"workspace-relative path"
    ~dec:(fun s ->
      match Rel.of_string s with
      | Ok rel -> rel
      | Error _ -> decode_error ("invalid workspace-relative path: " ^ s))
    ~enc:Rel.to_string Jsont.string

module String_id (Spec : sig
  val kind : string
end) =
struct
  type t = string

  let of_string s =
    if String.equal s "" then
      invalid_arg ("Spice_mutation." ^ Spec.kind ^ ": id must not be empty")
    else s

  let to_string t = t
  let equal = String.equal
  let compare = String.compare
  let pp = Format.pp_print_string

  let jsont =
    Jsont.map ~kind:Spec.kind
      ~dec:(fun s ->
        if String.equal s "" then decode_error (Spec.kind ^ " must not be empty")
        else s)
      ~enc:Fun.id Jsont.string
end

module Image = struct
  type t =
    | Missing
    | Text of { identity : Spice_digest.Identity.t; size : int }
    | Unsupported of { reason : string }

  let of_target = function
    | Spice_edit.Observed.Missing -> Missing
    | Spice_edit.Observed.Text contents ->
        Text
          {
            identity = Spice_digest.Identity.of_contents contents;
            size = String.length contents;
          }
    | Spice_edit.Observed.Other ->
        Unsupported { reason = "not a regular UTF-8 text file" }

  let equal a b =
    match (a, b) with
    | Missing, Missing -> true
    | Text a, Text b ->
        Spice_digest.Identity.equal a.identity b.identity
        && Int.equal a.size b.size
    | Unsupported a, Unsupported b -> String.equal a.reason b.reason
    | (Missing | Text _ | Unsupported _), _ -> false

  let pp ppf = function
    | Missing -> Format.pp_print_string ppf "missing"
    | Text { identity; size } ->
        Format.fprintf ppf "text(%a, %d bytes)" Spice_digest.Identity.pp
          identity size
    | Unsupported { reason } -> Format.fprintf ppf "unsupported(%s)" reason

  let jsont =
    let missing_case =
      Jsont.Object.map ~kind:"missing image" Missing
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "missing" ~dec:Fun.id
    in
    let text_case =
      Jsont.Object.map ~kind:"text image" (fun identity size ->
          Text { identity; size })
      |> Jsont.Object.mem "identity" Spice_digest.Identity.jsont ~enc:(function
        | Text { identity; _ } -> identity
        | Missing | Unsupported _ -> assert false)
      |> Jsont.Object.mem "size" Jsont.int ~enc:(function
        | Text { size; _ } -> size
        | Missing | Unsupported _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "text" ~dec:Fun.id
    in
    let unsupported_case =
      Jsont.Object.map ~kind:"unsupported image" (fun reason ->
          Unsupported { reason })
      |> Jsont.Object.mem "reason" Jsont.string ~enc:(function
        | Unsupported { reason } -> reason
        | Missing | Text _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "unsupported" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ missing_case; text_case; unsupported_case ]
    in
    let enc_case = function
      | Missing -> Jsont.Object.Case.value missing_case Missing
      | Text _ as image -> Jsont.Object.Case.value text_case image
      | Unsupported _ as image -> Jsont.Object.Case.value unsupported_case image
    in
    Jsont.Object.map ~kind:"image" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Checkpoint = struct
  module Id = String_id (struct
    let kind = "checkpoint id"
  end)

  type reason = Before_mutation | Run_end | Before_revert | Manual

  let reason_key = function
    | Before_mutation -> "before_mutation"
    | Run_end -> "run_end"
    | Before_revert -> "before_revert"
    | Manual -> "manual"

  let reason_jsont =
    Jsont.map ~kind:"checkpoint reason"
      ~dec:(function
        | "before_mutation" -> Before_mutation
        | "run_end" -> Run_end
        | "before_revert" -> Before_revert
        | "manual" -> Manual
        | other -> decode_error ("unknown checkpoint reason: " ^ other))
      ~enc:reason_key Jsont.string

  type status =
    | Available of { backend : string; reference : string; excluded : int }
    | Degraded of { backend : string; message : string }

  let status_jsont =
    let available_case =
      Jsont.Object.map ~kind:"available checkpoint"
        (fun backend reference excluded ->
          Available { backend; reference; excluded })
      |> Jsont.Object.mem "backend" Jsont.string ~enc:(function
        | Available { backend; _ } -> backend
        | Degraded _ -> assert false)
      |> Jsont.Object.mem "reference" Jsont.string ~enc:(function
        | Available { reference; _ } -> reference
        | Degraded _ -> assert false)
      |> Jsont.Object.mem "excluded" Jsont.int ~enc:(function
        | Available { excluded; _ } -> excluded
        | Degraded _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "available" ~dec:Fun.id
    in
    let degraded_case =
      Jsont.Object.map ~kind:"degraded checkpoint" (fun backend message ->
          Degraded { backend; message })
      |> Jsont.Object.mem "backend" Jsont.string ~enc:(function
        | Degraded { backend; _ } -> backend
        | Available _ -> assert false)
      |> Jsont.Object.mem "message" Jsont.string ~enc:(function
        | Degraded { message; _ } -> message
        | Available _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "degraded" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make [ available_case; degraded_case ]
    in
    let enc_case = function
      | Available _ as status -> Jsont.Object.Case.value available_case status
      | Degraded _ as status -> Jsont.Object.Case.value degraded_case status
    in
    Jsont.Object.map ~kind:"checkpoint status" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  type t = {
    id : Id.t;
    session : Spice_session.Id.t;
    turn : Spice_session.Turn.Id.t;
    root : string;
    reason : reason;
    status : status;
  }

  let make ~id ~session ~turn ~root ~reason ~status =
    { id; session; turn; root; reason; status }

  let derive_id ~session ~turn ~reason =
    Id.of_string
      (short_id "chk"
         [
           "checkpoint";
           Spice_session.Id.to_string session;
           Spice_session.Turn.Id.to_string turn;
           reason_key reason;
         ])

  let id t = t.id
  let session t = t.session
  let turn t = t.turn
  let root t = t.root
  let reason t = t.reason
  let status t = t.status

  let available_id t =
    match t.status with Available _ -> Some t.id | Degraded _ -> None

  let equal_reason a b =
    match (a, b) with
    | Before_mutation, Before_mutation
    | Run_end, Run_end
    | Before_revert, Before_revert
    | Manual, Manual ->
        true
    | (Before_mutation | Run_end | Before_revert | Manual), _ -> false

  let equal_status a b =
    match (a, b) with
    | Available a, Available b ->
        String.equal a.backend b.backend
        && String.equal a.reference b.reference
        && Int.equal a.excluded b.excluded
    | Degraded a, Degraded b ->
        String.equal a.backend b.backend && String.equal a.message b.message
    | (Available _ | Degraded _), _ -> false

  let equal a b =
    Id.equal a.id b.id
    && Spice_session.Id.equal a.session b.session
    && Spice_session.Turn.Id.equal a.turn b.turn
    && String.equal a.root b.root
    && equal_reason a.reason b.reason
    && equal_status a.status b.status

  let pp ppf t =
    Format.fprintf ppf "checkpoint(%a, %s)" Id.pp t.id (reason_key t.reason)

  let object' ~kind ~dec ~enc =
    Jsont.Object.map ~kind (fun id session turn root reason status ->
        dec (make ~id ~session ~turn ~root ~reason ~status))
    |> Jsont.Object.mem "id" Id.jsont ~enc:(fun v -> (enc v).id)
    |> Jsont.Object.mem "session" Spice_session.Id.jsont ~enc:(fun v ->
        (enc v).session)
    |> Jsont.Object.mem "turn" Spice_session.Turn.Id.jsont ~enc:(fun v ->
        (enc v).turn)
    |> Jsont.Object.mem "root" Jsont.string ~enc:(fun v -> (enc v).root)
    |> Jsont.Object.mem "reason" reason_jsont ~enc:(fun v -> (enc v).reason)
    |> Jsont.Object.mem "status" status_jsont ~enc:(fun v -> (enc v).status)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont = object' ~kind:"checkpoint" ~dec:Fun.id ~enc:Fun.id
end

module Revert_id = String_id (struct
  let kind = "revert id"
end)

module Change = struct
  module Id = String_id (struct
    let kind = "change id"
  end)

  type op = Create | Modify | Delete | Move of { from : Rel.t }

  type source =
    | Tool of {
        execution : Spice_session.Tool_claim.Id.t;
        call_id : string;
        tool : string;
      }
    | Revert of Revert_id.t

  type revertability = Revertable | Not_revertable of string

  type t = {
    id : Id.t;
    session : Spice_session.Id.t;
    turn : Spice_session.Turn.Id.t;
    source : source;
    path : Rel.t;
    op : op;
    before : Image.t;
    after : Image.t;
    additions : int;
    deletions : int;
    checkpoint : Checkpoint.Id.t option;
    revertability : revertability;
  }

  let make ?checkpoint ~id ~session ~turn ~source ~path ~op ~before ~after
      ~additions ~deletions ~revertability () =
    if additions < 0 then
      invalid_arg "Spice_mutation.Change.make: additions must be non-negative";
    if deletions < 0 then
      invalid_arg "Spice_mutation.Change.make: deletions must be non-negative";
    {
      id;
      session;
      turn;
      source;
      path;
      op;
      before;
      after;
      additions;
      deletions;
      checkpoint;
      revertability;
    }

  let derive_id ~execution ~path ~index =
    Id.of_string
      (short_id "change"
         [
           "change";
           Spice_session.Tool_claim.Id.to_string execution;
           Rel.to_string path;
           string_of_int index;
         ])

  let id t = t.id
  let session t = t.session
  let turn t = t.turn
  let source t = t.source
  let path t = t.path
  let op t = t.op
  let before t = t.before
  let after t = t.after
  let additions t = t.additions
  let deletions t = t.deletions
  let checkpoint t = t.checkpoint
  let revertability t = t.revertability

  type totals = { files : int; total_additions : int; total_deletions : int }

  let totals changes : totals =
    let paths =
      List.fold_left
        (fun paths (change : t) -> Rel.Set.add change.path paths)
        Rel.Set.empty changes
    in
    {
      files = Rel.Set.cardinal paths;
      total_additions =
        List.fold_left (fun n (c : t) -> n + c.additions) 0 changes;
      total_deletions =
        List.fold_left (fun n (c : t) -> n + c.deletions) 0 changes;
    }

  module Net = struct
    type entry = {
      path : Rel.t;
      before : Image.t;
      after : Image.t;
      contiguous : bool;
      sources : Id.t list;
    }

    type t = entry list
  end

  type net_acc = {
    first : Image.t;
    last : Image.t;
    contiguous : bool;
    rev_sources : Id.t list;
  }

  let deltas change =
    match change.op with
    | Create -> [ (change.path, Image.Missing, change.after, change.id) ]
    | Modify -> [ (change.path, change.before, change.after, change.id) ]
    | Delete -> [ (change.path, change.before, Image.Missing, change.id) ]
    | Move { from } ->
        [
          (from, change.before, Image.Missing, change.id);
          (change.path, Image.Missing, change.after, change.id);
        ]

  let net changes =
    let rev_order, map =
      List.fold_left
        (fun (rev_order, map) (path, before, after, id) ->
          match Rel.Map.find_opt path map with
          | None ->
              let acc =
                {
                  first = before;
                  last = after;
                  contiguous = true;
                  rev_sources = [ id ];
                }
              in
              (path :: rev_order, Rel.Map.add path acc map)
          | Some acc ->
              let acc =
                {
                  acc with
                  last = after;
                  contiguous = acc.contiguous && Image.equal acc.last before;
                  rev_sources = id :: acc.rev_sources;
                }
              in
              (rev_order, Rel.Map.add path acc map))
        ([], Rel.Map.empty)
        (List.concat_map deltas changes)
    in
    List.rev rev_order
    |> List.filter_map (fun path ->
        let acc = Rel.Map.find path map in
        if Image.equal acc.first acc.last then None
        else
          Some
            {
              Net.path;
              before = acc.first;
              after = acc.last;
              contiguous = acc.contiguous;
              sources = List.rev acc.rev_sources;
            })

  let equal_op a b =
    match (a, b) with
    | Create, Create | Modify, Modify | Delete, Delete -> true
    | Move a, Move b -> Rel.equal a.from b.from
    | (Create | Modify | Delete | Move _), _ -> false

  let equal_source a b =
    match (a, b) with
    | Tool a, Tool b ->
        Spice_session.Tool_claim.Id.equal a.execution b.execution
        && String.equal a.call_id b.call_id
        && String.equal a.tool b.tool
    | Revert a, Revert b -> Revert_id.equal a b
    | (Tool _ | Revert _), _ -> false

  let equal_revertability a b =
    match (a, b) with
    | Revertable, Revertable -> true
    | Not_revertable a, Not_revertable b -> String.equal a b
    | (Revertable | Not_revertable _), _ -> false

  let equal (a : t) (b : t) =
    Id.equal a.id b.id
    && Spice_session.Id.equal a.session b.session
    && Spice_session.Turn.Id.equal a.turn b.turn
    && equal_source a.source b.source
    && Rel.equal a.path b.path && equal_op a.op b.op
    && Image.equal a.before b.before
    && Image.equal a.after b.after
    && Int.equal a.additions b.additions
    && Int.equal a.deletions b.deletions
    && Option.equal Checkpoint.Id.equal a.checkpoint b.checkpoint
    && equal_revertability a.revertability b.revertability

  let op_key = function
    | Create -> "create"
    | Modify -> "modify"
    | Delete -> "delete"
    | Move _ -> "move"

  let pp ppf t =
    Format.fprintf ppf "change(%a, %s %a)" Id.pp t.id (op_key t.op) Rel.pp
      t.path

  let op_jsont =
    let constant_case kind key value =
      Jsont.Object.map ~kind value
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map key ~dec:Fun.id
    in
    let create_case = constant_case "create op" "create" Create in
    let modify_case = constant_case "modify op" "modify" Modify in
    let delete_case = constant_case "delete op" "delete" Delete in
    let move_case =
      Jsont.Object.map ~kind:"move op" (fun from -> Move { from })
      |> Jsont.Object.mem "from" rel_jsont ~enc:(function
        | Move { from } -> from
        | Create | Modify | Delete -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "move" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ create_case; modify_case; delete_case; move_case ]
    in
    let enc_case = function
      | Create -> Jsont.Object.Case.value create_case Create
      | Modify -> Jsont.Object.Case.value modify_case Modify
      | Delete -> Jsont.Object.Case.value delete_case Delete
      | Move _ as op -> Jsont.Object.Case.value move_case op
    in
    Jsont.Object.map ~kind:"change op" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let source_jsont =
    let tool_case =
      Jsont.Object.map ~kind:"tool source" (fun execution call_id tool ->
          Tool { execution; call_id; tool })
      |> Jsont.Object.mem "execution" Spice_session.Tool_claim.Id.jsont
           ~enc:(function
           | Tool { execution; _ } -> execution
           | Revert _ -> assert false)
      |> Jsont.Object.mem "call_id" Jsont.string ~enc:(function
        | Tool { call_id; _ } -> call_id
        | Revert _ -> assert false)
      |> Jsont.Object.mem "tool" Jsont.string ~enc:(function
        | Tool { tool; _ } -> tool
        | Revert _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "tool" ~dec:Fun.id
    in
    let revert_case =
      Jsont.Object.map ~kind:"revert source" (fun id -> Revert id)
      |> Jsont.Object.mem "revert" Revert_id.jsont ~enc:(function
        | Revert id -> id
        | Tool _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "revert" ~dec:Fun.id
    in
    let cases = List.map Jsont.Object.Case.make [ tool_case; revert_case ] in
    let enc_case = function
      | Tool _ as source -> Jsont.Object.Case.value tool_case source
      | Revert _ as source -> Jsont.Object.Case.value revert_case source
    in
    Jsont.Object.map ~kind:"change source" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let revertability_jsont =
    let revertable_case =
      Jsont.Object.map ~kind:"revertable" Revertable
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "revertable" ~dec:Fun.id
    in
    let not_revertable_case =
      Jsont.Object.map ~kind:"not revertable" (fun reason ->
          Not_revertable reason)
      |> Jsont.Object.mem "reason" Jsont.string ~enc:(function
        | Not_revertable reason -> reason
        | Revertable -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "not_revertable" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make [ revertable_case; not_revertable_case ]
    in
    let enc_case = function
      | Revertable -> Jsont.Object.Case.value revertable_case Revertable
      | Not_revertable _ as r -> Jsont.Object.Case.value not_revertable_case r
    in
    Jsont.Object.map ~kind:"revertability" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let object' ~kind ~dec ~enc =
    Jsont.Object.map ~kind
      (fun
        id
        session
        turn
        source
        path
        op
        before
        after
        additions
        deletions
        checkpoint
        revertability
      ->
        dec
          (make ?checkpoint ~id ~session ~turn ~source ~path ~op ~before ~after
             ~additions ~deletions ~revertability ()))
    |> Jsont.Object.mem "id" Id.jsont ~enc:(fun v -> (enc v).id)
    |> Jsont.Object.mem "session" Spice_session.Id.jsont ~enc:(fun v ->
        (enc v).session)
    |> Jsont.Object.mem "turn" Spice_session.Turn.Id.jsont ~enc:(fun v ->
        (enc v).turn)
    |> Jsont.Object.mem "source" source_jsont ~enc:(fun v -> (enc v).source)
    |> Jsont.Object.mem "path" rel_jsont ~enc:(fun v -> (enc v).path)
    |> Jsont.Object.mem "op" op_jsont ~enc:(fun v -> (enc v).op)
    |> Jsont.Object.mem "before" Image.jsont ~enc:(fun v -> (enc v).before)
    |> Jsont.Object.mem "after" Image.jsont ~enc:(fun v -> (enc v).after)
    |> Jsont.Object.mem "additions" Jsont.int ~enc:(fun v ->
        (enc v : t).additions)
    |> Jsont.Object.mem "deletions" Jsont.int ~enc:(fun v ->
        (enc v : t).deletions)
    |> Jsont.Object.opt_mem "checkpoint" Checkpoint.Id.jsont ~enc:(fun v ->
        (enc v).checkpoint)
    |> Jsont.Object.mem "revertability" revertability_jsont ~enc:(fun v ->
        (enc v).revertability)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont = object' ~kind:"change" ~dec:Fun.id ~enc:Fun.id
end

module Scope = struct
  type t =
    | Session
    | Turn of Spice_session.Turn.Id.t
    | Turns of Spice_session.Turn.Id.t list
    | Change of Change.Id.t
    | Path of Rel.t

  let select t changes =
    match t with
    | Session -> changes
    | Turn turn ->
        List.filter
          (fun change -> Spice_session.Turn.Id.equal (Change.turn change) turn)
          changes
    | Turns turns ->
        List.filter
          (fun change ->
            List.exists (Spice_session.Turn.Id.equal (Change.turn change)) turns)
          changes
    | Change id ->
        List.filter
          (fun change -> Change.Id.equal (Change.id change) id)
          changes
    | Path path ->
        List.filter
          (fun change ->
            Rel.equal (Change.path change) path
            ||
            match Change.op change with
            | Change.Move { from } -> Rel.equal from path
            | Change.Create | Change.Modify | Change.Delete -> false)
          changes

  let key = function
    | Session -> "session"
    | Turn turn -> "turn:" ^ Spice_session.Turn.Id.to_string turn
    | Turns turns ->
        "turns:"
        ^ String.concat "," (List.map Spice_session.Turn.Id.to_string turns)
    | Change id -> "change:" ^ Change.Id.to_string id
    | Path path -> "path:" ^ Rel.to_string path

  let equal a b =
    match (a, b) with
    | Session, Session -> true
    | Turn a, Turn b -> Spice_session.Turn.Id.equal a b
    | Turns a, Turns b -> List.equal Spice_session.Turn.Id.equal a b
    | Change a, Change b -> Change.Id.equal a b
    | Path a, Path b -> Rel.equal a b
    | (Session | Turn _ | Turns _ | Change _ | Path _), _ -> false

  let pp ppf t = Format.pp_print_string ppf (key t)

  let jsont =
    let session_case =
      Jsont.Object.map ~kind:"session scope" Session
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "session" ~dec:Fun.id
    in
    let turn_case =
      Jsont.Object.map ~kind:"turn scope" (fun turn -> Turn turn)
      |> Jsont.Object.mem "turn" Spice_session.Turn.Id.jsont ~enc:(function
        | Turn turn -> turn
        | Session | Turns _ | Change _ | Path _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "turn" ~dec:Fun.id
    in
    let turns_case =
      Jsont.Object.map ~kind:"turns scope" (fun turns -> Turns turns)
      |> Jsont.Object.mem "turns" (Jsont.list Spice_session.Turn.Id.jsont)
           ~enc:(function
           | Turns turns -> turns
           | Session | Turn _ | Change _ | Path _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "turns" ~dec:Fun.id
    in
    let change_case =
      Jsont.Object.map ~kind:"change scope" (fun id -> Change id)
      |> Jsont.Object.mem "change" Change.Id.jsont ~enc:(function
        | Change id -> id
        | Session | Turn _ | Turns _ | Path _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "change" ~dec:Fun.id
    in
    let path_case =
      Jsont.Object.map ~kind:"path scope" (fun path -> Path path)
      |> Jsont.Object.mem "path" rel_jsont ~enc:(function
        | Path path -> path
        | Session | Turn _ | Turns _ | Change _ -> assert false)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "path" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ session_case; turn_case; turns_case; change_case; path_case ]
    in
    let enc_case = function
      | Session -> Jsont.Object.Case.value session_case Session
      | Turn _ as scope -> Jsont.Object.Case.value turn_case scope
      | Turns _ as scope -> Jsont.Object.Case.value turns_case scope
      | Change _ as scope -> Jsont.Object.Case.value change_case scope
      | Path _ as scope -> Jsont.Object.Case.value path_case scope
    in
    Jsont.Object.map ~kind:"scope" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

module Revert = struct
  type stale = { stale_path : Rel.t; expected : Image.t; actual : Image.t }
  type refusal = { refusal_path : Rel.t; reason : string }
  type problem = Stale of stale | Refused of refusal

  type ready = {
    ready_path : Rel.t;
    current : string option;
    restore : Image.t;
    sources : Change.Id.t list;
  }

  type plan = { ready : ready list; problems : problem list }

  let plan ~read ~scope changes =
    let entries = Change.net (Scope.select scope changes) in
    let ready, problems =
      List.fold_left
        (fun (ready, problems) (entry : Change.Net.entry) ->
          let refused reason =
            ( ready,
              Refused
                ({ refusal_path = entry.Change.Net.path; reason } : refusal)
              :: problems )
          in
          match entry.Change.Net.before with
          | Image.Unsupported { reason } ->
              refused ("recorded before image is unsupported: " ^ reason)
          | Image.Missing | Image.Text _ -> (
              match entry.Change.Net.after with
              | Image.Unsupported { reason } ->
                  refused ("recorded after image is unsupported: " ^ reason)
              | Image.Missing | Image.Text _ -> (
                  let target = read entry.Change.Net.path in
                  match target with
                  | Spice_edit.Observed.Other ->
                      refused "current target is not an editable text file"
                  | Spice_edit.Observed.Missing | Spice_edit.Observed.Text _ ->
                      let current_image = Image.of_target target in
                      if Image.equal current_image entry.Change.Net.after then
                        let current =
                          match target with
                          | Spice_edit.Observed.Text contents -> Some contents
                          | Spice_edit.Observed.Missing
                          | Spice_edit.Observed.Other ->
                              None
                        in
                        ( {
                            ready_path = entry.Change.Net.path;
                            current;
                            restore = entry.Change.Net.before;
                            sources = entry.Change.Net.sources;
                          }
                          :: ready,
                          problems )
                      else
                        ( ready,
                          Stale
                            ({
                               stale_path = entry.Change.Net.path;
                               expected = entry.Change.Net.after;
                               actual = current_image;
                             }
                              : stale)
                          :: problems ))))
        ([], []) entries
    in
    { ready = List.rev ready; problems = List.rev problems }

  let lower plan ~resolve ~blob =
    match plan.problems with
    | _ :: _ -> Error plan.problems
    | [] -> (
        let edits, rev_problems =
          List.fold_left
            (fun (edits, problems) (ready : ready) ->
              let refused reason =
                ( edits,
                  Refused
                    ({ refusal_path = ready.ready_path; reason } : refusal)
                  :: problems )
              in
              match resolve ready.ready_path with
              | Error reason -> refused ("path resolution failed: " ^ reason)
              | Ok path -> (
                  match (ready.restore, ready.current) with
                  | Image.Unsupported { reason }, _ ->
                      refused ("recorded before image is unsupported: " ^ reason)
                  | Image.Missing, None -> refused "nothing to restore"
                  | Image.Missing, Some current -> (
                      match Spice_edit.delete ~path ~before:current with
                      | Ok edit -> (edit :: edits, problems)
                      | Error error -> refused (Spice_edit.Error.message error))
                  | Image.Text { identity; _ }, current -> (
                      match blob identity with
                      | None -> refused "evidence blob missing"
                      | Some contents -> (
                          if
                            not
                              (Spice_digest.Identity.equal
                                 (Spice_digest.Identity.of_contents contents)
                                 identity)
                          then refused "evidence blob corrupt"
                          else
                            match current with
                            | Some before -> (
                                match
                                  Spice_edit.rewrite ~path ~before
                                    ~after:contents
                                with
                                | Ok edit -> (edit :: edits, problems)
                                | Error error ->
                                    refused (Spice_edit.Error.message error))
                            | None -> (
                                match Spice_edit.create ~path ~contents with
                                | Ok edit -> (edit :: edits, problems)
                                | Error error ->
                                    refused (Spice_edit.Error.message error))))))
            ([], []) plan.ready
        in
        match rev_problems with
        | _ :: _ -> Error (List.rev rev_problems)
        | [] -> (
            match Spice_edit.concat (List.rev edits) with
            | Ok edit -> Ok edit
            | Error error ->
                let path =
                  match Spice_edit.Error.path error with
                  | Some path -> Spice_workspace.Path.rel path
                  | None -> (
                      match plan.ready with
                      | ready :: _ -> ready.ready_path
                      | [] -> Rel.root)
                in
                Error
                  [
                    Refused
                      ({
                         refusal_path = path;
                         reason = Spice_edit.Error.message error;
                       }
                        : refusal);
                  ]))

  type applied = { applied_path : Rel.t; applied_sources : Change.Id.t list }

  type t = {
    id : Revert_id.t;
    session : Spice_session.Id.t;
    scope : Scope.t;
    pre_revert : Checkpoint.Id.t option;
    applied : applied list;
  }

  let make ?pre_revert ~id ~session ~scope ~applied () =
    { id; session; scope; pre_revert; applied }

  let derive_id ~session ~scope ~ordinal =
    Revert_id.of_string
      (short_id "revert"
         [
           "revert";
           Spice_session.Id.to_string session;
           Scope.key scope;
           string_of_int ordinal;
         ])

  let id t = t.id
  let session t = t.session
  let scope t = t.scope
  let pre_revert t = t.pre_revert
  let applied t = t.applied

  let equal_applied (a : applied) (b : applied) =
    Rel.equal a.applied_path b.applied_path
    && List.equal Change.Id.equal a.applied_sources b.applied_sources

  let equal a b =
    Revert_id.equal a.id b.id
    && Spice_session.Id.equal a.session b.session
    && Scope.equal a.scope b.scope
    && Option.equal Checkpoint.Id.equal a.pre_revert b.pre_revert
    && List.equal equal_applied a.applied b.applied

  let pp ppf t =
    Format.fprintf ppf "revert(%a, %a)" Revert_id.pp t.id Scope.pp t.scope

  (* The persisted per-path result is applied-only, but the [case_mem "kind"]
     tagged-union wire shape is retained so legacy {"kind":"applied",...} rows
     decode byte-identically. A legacy "stale"/"refused" kind (never written in
     production) now fails to decode loudly, which is correct. *)
  let applied_jsont =
    let applied_case =
      Jsont.Object.map ~kind:"applied path" (fun path sources ->
          { applied_path = path; applied_sources = sources })
      |> Jsont.Object.mem "path" rel_jsont ~enc:(fun (a : applied) ->
          a.applied_path)
      |> Jsont.Object.mem "sources" (Jsont.list Change.Id.jsont)
           ~enc:(fun (a : applied) -> a.applied_sources)
      |> Jsont.Object.error_unknown |> Jsont.Object.finish
      |> Jsont.Object.Case.map "applied" ~dec:Fun.id
    in
    let cases = [ Jsont.Object.Case.make applied_case ] in
    let enc_case a = Jsont.Object.Case.value applied_case a in
    Jsont.Object.map ~kind:"revert path result" Fun.id
    |> Jsont.Object.case_mem "kind" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let object' ~kind ~dec ~enc =
    Jsont.Object.map ~kind (fun id session scope pre_revert applied ->
        dec (make ?pre_revert ~id ~session ~scope ~applied ()))
    |> Jsont.Object.mem "id" Revert_id.jsont ~enc:(fun v -> (enc v).id)
    |> Jsont.Object.mem "session" Spice_session.Id.jsont ~enc:(fun v ->
        (enc v).session)
    |> Jsont.Object.mem "scope" Scope.jsont ~enc:(fun v -> (enc v).scope)
    |> Jsont.Object.opt_mem "pre_revert" Checkpoint.Id.jsont ~enc:(fun v ->
        (enc v).pre_revert)
    |> Jsont.Object.mem "results" (Jsont.list applied_jsont) ~enc:(fun v ->
        (enc v).applied)
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let jsont = object' ~kind:"revert" ~dec:Fun.id ~enc:Fun.id
end

module Record = struct
  type t =
    | Checkpoint of Checkpoint.t
    | Change of Change.t
    | Revert of Revert.t

  let equal a b =
    match (a, b) with
    | Checkpoint a, Checkpoint b -> Checkpoint.equal a b
    | Change a, Change b -> Change.equal a b
    | Revert a, Revert b -> Revert.equal a b
    | (Checkpoint _ | Change _ | Revert _), _ -> false

  let pp ppf = function
    | Checkpoint checkpoint -> Checkpoint.pp ppf checkpoint
    | Change change -> Change.pp ppf change
    | Revert revert -> Revert.pp ppf revert

  let jsont =
    let checkpoint_case =
      Checkpoint.object' ~kind:"checkpoint record"
        ~dec:(fun checkpoint -> Checkpoint checkpoint)
        ~enc:(function
          | Checkpoint checkpoint -> checkpoint
          | Change _ | Revert _ -> assert false)
      |> Jsont.Object.Case.map "checkpoint" ~dec:Fun.id
    in
    let change_case =
      Change.object' ~kind:"change record"
        ~dec:(fun change -> Change change)
        ~enc:(function
          | Change change -> change | Checkpoint _ | Revert _ -> assert false)
      |> Jsont.Object.Case.map "change" ~dec:Fun.id
    in
    let revert_case =
      Revert.object' ~kind:"revert record"
        ~dec:(fun revert -> Revert revert)
        ~enc:(function
          | Revert revert -> revert | Checkpoint _ | Change _ -> assert false)
      |> Jsont.Object.Case.map "revert" ~dec:Fun.id
    in
    let cases =
      List.map Jsont.Object.Case.make
        [ checkpoint_case; change_case; revert_case ]
    in
    let enc_case = function
      | Checkpoint _ as record -> Jsont.Object.Case.value checkpoint_case record
      | Change _ as record -> Jsont.Object.Case.value change_case record
      | Revert _ as record -> Jsont.Object.Case.value revert_case record
    in
    Jsont.Object.map ~kind:"mutation record" Fun.id
    |> Jsont.Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Jsont.Object.error_unknown |> Jsont.Object.finish
end

let changes records =
  List.filter_map
    (function Record.Change change -> Some change | _ -> None)
    records

let checkpoints records =
  List.filter_map
    (function Record.Checkpoint checkpoint -> Some checkpoint | _ -> None)
    records

let find_checkpoint records id =
  List.find_opt
    (fun checkpoint -> Checkpoint.Id.equal (Checkpoint.id checkpoint) id)
    (checkpoints records)

let reverts records =
  List.filter_map
    (function Record.Revert revert -> Some revert | _ -> None)
    records
