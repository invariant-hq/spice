(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Key = Matrix.Input.Key
module Modifier = Matrix.Input.Modifier

(* {1 Effects} *)

type request = int

module Effect = struct
  type t =
    | Snapshot of { request : request; base_spec : string option }
    | Store of { root : string; key : string; record : Spice_review.Persist.t }
    | Watch of { root : string }
    | Watch_stop
    | Sleep of { request : Spice_review.Live.Request.t; seconds : float }
    | Load of {
        request : Spice_review.Live.Request.t;
        root : string;
        base : string;
        known : string option;
      }
    | Mutate of {
        request : Spice_review.Live.Request.t;
        root : string;
        base : string;
        expected : string;
        op : Spice_review.Op.t;
      }
end

(* {1 Messages} *)

(* The loader result the runtime feeds back through {!opened}. The [ro_] prefix
   keeps these fields disjoint from {!screen}'s so record disambiguation stays
   unambiguous. *)
type opened = {
  ro_root : string;
  ro_base : string;
  ro_range : string;
  ro_store_key : string;
  ro_feature : Spice_review.Feature.t;
  ro_crs : Spice_cr.Occurrence.t list;
  ro_fingerprint : string;
  ro_persisted : Spice_review.Persist.t option;
  ro_resolver : string;
}

let snapshot ~root ~base ~range ~store_key ~resolver ~feature ~crs ~fingerprint
    ?persisted () =
  {
    ro_root = root;
    ro_base = base;
    ro_range = range;
    ro_store_key = store_key;
    ro_resolver = resolver;
    ro_feature = feature;
    ro_crs = crs;
    ro_fingerprint = fingerprint;
    ro_persisted = persisted;
  }

type msg =
  | Opened of request * (opened, string) result
  | Fs_changed of float
  | Tick of Spice_review.Live.Request.t * float
  | Loaded of
      Spice_review.Live.Request.t
      * ([ `Unchanged | `Loaded of Spice_review.Live.load ], string) result
  | Watch_failed of string
  | Moved of Spice_review.Cursor.move
  | Line_moved of [ `Next | `Previous ]
  | Hunk_jumped of [ `Next | `Previous ]
  | Focus_toggled
  | Nav_clicked of Spice_review.Cursor.t
  | Line_clicked of Spice_review.Scope.t
  | Entered
  | Back
  | Space_pressed
  | Verdict_toggled
  | Help_toggled
  | Context_toggled
  | Agent_requested
  | Save_failed of string
  | Compose_started of [ `Add | `Edit | `Resolve ]
  | Compose_char of string
  | Compose_backspace
  | Compose_cancelled
  | Compose_submitted
  | Remove_requested
  | Mutated of
      Spice_review.Live.Request.t * (Spice_review.Live.load, string) result
  | Close_pressed

(* {2 Runtime-built completions} *)

let opened ~request result = Opened (request, result)
let fs_changed ~now = Fs_changed now
let tick request ~now = Tick (request, now)
let loaded request result = Loaded (request, result)
let mutated request result = Mutated (request, result)
let watch_failed message = Watch_failed message
let save_failed message = Save_failed message

(* {1 Lifecycle} *)

(* The live protocol state and the view-local orientation for one open review.
   Its review value ({!Spice_review.Live.review}) is authoritative. *)
type screen = {
  live : Spice_review.Live.t;
  root : string;
  base : string;
  range : string;
  store_key : string;
  resolver : string;
  pending_notice : string option;
      (* Settle wording for the in-flight CR mutation, e.g. "CR removed". *)
  panel : Review_panel.state;
}

type t =
  | Loading of { request : request; base_spec : string option }
  | Failed of string
  | Open of screen

type event =
  | Stay of Effect.t list
  | Close of Effect.t list
  | Task_spice of Effect.t list

(* The component owns the {!request} counter; only {!create} draws from it. *)
let counter = ref 0

let create ?base_spec () =
  let request = !counter in
  incr counter;
  (Loading { request; base_spec }, [ Effect.Snapshot { request; base_spec } ])

let screen_review screen = Spice_review.Live.review screen.live

(* Pure review-state edits keep [Live]'s copy authoritative; user-authored
   state (marks, verdict) persists on every change, orientation on close. *)
let set ?(save = false) screen review' =
  let live, _ =
    Spice_review.Live.step screen.live
      (Spice_review.Live.Review_changed review')
  in
  let screen = { screen with live } in
  let effects =
    if save then
      [
        Effect.Store
          {
            root = screen.root;
            key = screen.store_key;
            record = Spice_review.Persist.of_review review';
          };
      ]
    else []
  in
  (Open screen, effects)

let notify screen ~text ~warning =
  ( Open
      {
        screen with
        panel = Review_panel.set_notice screen.panel ~text ~warning;
      },
    [] )

(* Close bookkeeping: persist the latest state and stop the watch. The event
   ({!Close} or {!Task_spice}) carries these; there is no terminal [Closed]
   effect — the shell decides what to do with the surface. *)
let close_effects t =
  match t with
  | Open screen ->
      [
        Effect.Store
          {
            root = screen.root;
            key = screen.store_key;
            record = Spice_review.Persist.of_review (screen_review screen);
          };
        Effect.Watch_stop;
      ]
  | Loading _ | Failed _ -> [ Effect.Watch_stop ]

(* {2 Line navigation and scopes} *)

(* The hunks of the cursor's file, for line navigation and containment. *)
let file_hunks review path =
  match Spice_review.Feature.find_file (Spice_review.feature review) ~path with
  | None -> []
  | Some file -> (
      match Spice_review.Feature.File.content file with
      | Spice_review.Feature.File.Text hunks -> hunks
      | Spice_review.Feature.File.Opaque _ -> [])

let containing_hunk review ~path scope =
  List.find_opt
    (fun hunk ->
      Spice_review.Scope.contains (Spice_review.Scope.of_hunk ~path hunk) scope)
    (file_hunks review path)

(* Line navigation: the diff pane's cursor steps over every displayed line
   of the selected file, in hunk order. Added and context lines anchor on the
   new side, removed lines on the old side — the same sides source comments
   can attach to. *)
let line_targets review path =
  List.concat_map
    (fun hunk ->
      List.filter_map
        (fun line ->
          match Spice_diff.Hunk.Line.new_line line with
          | Some n -> Some (Spice_review.Scope.New, n)
          | None ->
              Option.map
                (fun n -> (Spice_review.Scope.Old, n))
                (Spice_diff.Hunk.Line.old_line line))
        (Spice_diff.Hunk.lines hunk))
    (file_hunks review path)

let hunk_first_changed_line ~path hunk =
  let lines = Spice_diff.Hunk.lines hunk in
  let changed =
    List.find_opt
      (fun line ->
        match Spice_diff.Hunk.Line.kind line with
        | Spice_diff.Hunk.Line.Added | Spice_diff.Hunk.Line.Removed -> true
        | Spice_diff.Hunk.Line.Context -> false)
      lines
  in
  let line =
    match changed with Some line -> Some line | None -> List.nth_opt lines 0
  in
  match line with
  | None -> None
  | Some line -> (
      match Spice_diff.Hunk.Line.new_line line with
      | Some n ->
          Some (Spice_review.Scope.Line (Spice_review.Scope.New, path, n))
      | None ->
          Option.map
            (fun n -> Spice_review.Scope.Line (Spice_review.Scope.Old, path, n))
            (Spice_diff.Hunk.Line.old_line line))

(* The cursor's file path, and its position among the file's line targets. *)
let cursor_path review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Scope scope -> Spice_review.Scope.path scope
  | Spice_review.Cursor.Cr index ->
      Option.map Spice_cr.Occurrence.path (Spice_review.cr review index)

let line_index review path targets =
  let find side line =
    let rec go i = function
      | [] -> None
      | (s, n) :: rest ->
          if
            Int.equal n line
            &&
            match (s, side) with
            | Spice_review.Scope.New, Spice_review.Scope.New
            | Spice_review.Scope.Old, Spice_review.Scope.Old ->
                true
            | _ -> false
          then Some i
          else go (i + 1) rest
    in
    go 0 targets
  in
  match Spice_review.cursor review with
  | Spice_review.Cursor.Scope scope -> (
      match scope with
      | Spice_review.Scope.Line (side, _, line) -> find side line
      | Spice_review.Scope.Hunk { path = hunk_path; _ } ->
          Option.bind (containing_hunk review ~path:hunk_path scope)
            (fun hunk ->
              Option.bind (hunk_first_changed_line ~path hunk) (fun scope ->
                  match scope with
                  | Spice_review.Scope.Line (side, _, line) -> find side line
                  | _ -> None))
      | _ -> None)
  | Spice_review.Cursor.Cr index ->
      Option.bind (Spice_review.cr review index) (fun occ ->
          find Spice_review.Scope.New (Spice_cr.Occurrence.line occ))

(* Step the line cursor. From non-line cursors, the first step lands on the
   file's first changed line rather than moving blindly. *)
let line_step review direction =
  match cursor_path review with
  | None -> review
  | Some path -> (
      let targets = line_targets review path in
      if List.is_empty targets then review
      else
        let last = List.length targets - 1 in
        let index =
          match line_index review path targets with
          | Some index -> (
              match direction with
              | `Next -> min last (index + 1)
              | `Previous -> max 0 (index - 1))
          | None -> 0
        in
        let side, line = List.nth targets index in
        match
          Spice_review.set_cursor review
            (Spice_review.Cursor.Scope
               (Spice_review.Scope.Line (side, path, line)))
        with
        | Ok review -> review
        | Error _ -> review)

(* Jump hunks from a line cursor: the first changed line of the adjacent
   hunk. *)
let hunk_jump review direction =
  match cursor_path review with
  | None -> review
  | Some path -> (
      let hunks = file_hunks review path in
      if List.is_empty hunks then review
      else
        let containing =
          match Spice_review.cursor review with
          | Spice_review.Cursor.Scope scope ->
              let rec index i = function
                | [] -> None
                | hunk :: rest ->
                    if
                      Spice_review.Scope.contains
                        (Spice_review.Scope.of_hunk ~path hunk)
                        scope
                      || Spice_review.Scope.equal
                           (Spice_review.Scope.of_hunk ~path hunk)
                           scope
                    then Some i
                    else index (i + 1) rest
              in
              index 0 hunks
          | Spice_review.Cursor.Cr _ -> None
        in
        let last = List.length hunks - 1 in
        let index =
          match (containing, direction) with
          | Some i, `Next -> min last (i + 1)
          | Some i, `Previous -> max 0 (i - 1)
          | None, _ -> 0
        in
        match
          Option.bind (List.nth_opt hunks index) (hunk_first_changed_line ~path)
        with
        | None -> review
        | Some scope -> (
            match
              Spice_review.set_cursor review (Spice_review.Cursor.Scope scope)
            with
            | Ok review -> review
            | Error _ -> review))

(* Entering the diff pane seeds the line cursor at the first changed line of
   whatever the nav had selected. *)
let seed_line review =
  let set scope =
    match Spice_review.set_cursor review (Spice_review.Cursor.Scope scope) with
    | Ok review -> review
    | Error _ -> review
  in
  let first_of_file path =
    Option.bind
      (List.nth_opt (file_hunks review path) 0)
      (hunk_first_changed_line ~path)
  in
  match Spice_review.cursor review with
  | Spice_review.Cursor.Cr _ -> review
  | Spice_review.Cursor.Scope scope -> (
      match scope with
      | Spice_review.Scope.Line _ -> review
      | Spice_review.Scope.Hunk { path; _ } -> (
          match
            Option.bind
              (containing_hunk review ~path scope)
              (hunk_first_changed_line ~path)
          with
          | Some line_scope -> set line_scope
          | None -> review)
      | Spice_review.Scope.File path -> (
          match first_of_file path with
          | Some line_scope -> set line_scope
          | None -> review)
      | Spice_review.Scope.Feature -> review)

(* Space marks the unit of coverage: the hunk. A line cursor marks its
   containing hunk; comments, not marks, are the line-level gesture. *)
let space_scope review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Cr _ -> None
  | Spice_review.Cursor.Scope scope -> (
      match scope with
      | Spice_review.Scope.Feature -> None
      | Spice_review.Scope.File _ | Spice_review.Scope.Hunk _ -> Some scope
      | Spice_review.Scope.Line (_, path, _) ->
          Option.map
            (fun hunk -> Spice_review.Scope.of_hunk ~path hunk)
            (containing_hunk review ~path scope))

(* {2 Live refresh} *)

(* A refresh notice says what changed, per 11-review.md: unit and CR deltas,
   and whether the refresh staled the verdict (the one warning case). *)
let refresh_staled ~before ~after =
  match
    (Spice_review.verdict_freshness before, Spice_review.verdict_freshness after)
  with
  | `Approved, `Stale -> true
  | (`Approved | `Pending | `Stale), _ -> false

let refresh_notice ~before ~after =
  let count word n =
    Printf.sprintf "%d %s%s" (abs n) word (if abs n = 1 then "" else "s")
  in
  let unit_delta = Spice_review.units after - Spice_review.units before in
  let cr_delta = Spice_review.open_crs after - Spice_review.open_crs before in
  let parts =
    (if unit_delta > 0 then [ count "new unit" unit_delta ]
     else if unit_delta < 0 then [ count "unit" unit_delta ^ " removed" ]
     else [])
    @ (if cr_delta > 0 then [ count "new CR" cr_delta ]
       else if cr_delta < 0 then [ count "CR" cr_delta ^ " resolved" ]
       else [])
    @ if refresh_staled ~before ~after then [ "verdict stale" ] else []
  in
  match parts with
  | [] -> "refreshed"
  | parts -> "refreshed · " ^ String.concat " · " parts

(* Feed one event through the live protocol and interpret its actions:
   sleeps and loads become effects, a replace re-renders with a notice and
   persists, an error keeps the old review visible. *)
let live_step screen event =
  let before = screen_review screen in
  let live, actions = Spice_review.Live.step screen.live event in
  let screen = { screen with live } in
  let apply (screen, effects) = function
    | Spice_review.Live.Sleep { request; seconds } ->
        (screen, Effect.Sleep { request; seconds } :: effects)
    | Spice_review.Live.Load { request; known } ->
        ( screen,
          Effect.Load { request; root = screen.root; base = screen.base; known }
          :: effects )
    | Spice_review.Live.Replace review ->
        ( {
            screen with
            panel =
              Review_panel.set_notice screen.panel
                ~text:(refresh_notice ~before ~after:review)
                ~warning:(refresh_staled ~before ~after:review);
          },
          Effect.Store
            {
              root = screen.root;
              key = screen.store_key;
              record = Spice_review.Persist.of_review review;
            }
          :: effects )
    | Spice_review.Live.Error message ->
        ( {
            screen with
            panel =
              Review_panel.set_notice screen.panel
                ~text:("refresh failed: " ^ message)
                ~warning:true;
          },
          effects )
  in
  let screen, effects = List.fold_left apply (screen, []) actions in
  (Open screen, List.rev effects)

(* {2 CR compose} *)

let cursor_cr review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Cr index ->
      Option.map (fun occ -> (index, occ)) (Spice_review.cr review index)
  | Spice_review.Cursor.Scope _ -> None

(* Where [c] anchors a new CR: the selected line, the selected hunk's first
   new-side line, a file's first hunk, or the selected CR's own line. An
   old-side (removed) line does not exist in the worktree, so the CR anchors on
   the new-side line now sitting where it was: the removed line's own new number
   when it is a context line, else the first following line that survived, else
   just past the hunk's new range. Anchoring on the right worktree line is also
   what gives the comment the right indentation — [Spice_cr.add_before_line]
   indents like its target line. *)
let worktree_line review ~path side line =
  match side with
  | Spice_review.Scope.New -> Some line
  | Spice_review.Scope.Old ->
      let scope = Spice_review.Scope.Line (side, path, line) in
      Option.bind (containing_hunk review ~path scope) (fun hunk ->
          let lines = Spice_diff.Hunk.lines hunk in
          let rec find = function
            | [] -> None
            | candidate :: rest -> (
                match Spice_diff.Hunk.Line.old_line candidate with
                | Some n when Int.equal n line -> (
                    match Spice_diff.Hunk.Line.new_line candidate with
                    | Some new_line -> Some new_line
                    | None -> List.find_map Spice_diff.Hunk.Line.new_line rest)
                | _ -> find rest)
          in
          match find lines with
          | Some new_line -> Some new_line
          | None ->
              Some
                (Spice_diff.Hunk.new_start hunk + Spice_diff.Hunk.new_count hunk))

let add_anchor review =
  match Spice_review.cursor review with
  | Spice_review.Cursor.Cr index ->
      Option.map
        (fun occ ->
          (Spice_cr.Occurrence.path occ, Spice_cr.Occurrence.line occ))
        (Spice_review.cr review index)
  | Spice_review.Cursor.Scope scope -> (
      match scope with
      | Spice_review.Scope.Feature -> None
      | Spice_review.Scope.Line (side, path, line) ->
          Option.map
            (fun line -> (path, line))
            (worktree_line review ~path side line)
      | Spice_review.Scope.Hunk { path; new_start; new_count; _ } ->
          Some (path, if new_count > 0 then new_start else 1)
      | Spice_review.Scope.File path -> (
          match
            Spice_review.Feature.find_file (Spice_review.feature review) ~path
          with
          | Some file -> (
              match Spice_review.Feature.File.content file with
              | Spice_review.Feature.File.Text (hunk :: _) ->
                  Some (path, Spice_diff.Hunk.new_start hunk)
              | Spice_review.Feature.File.Text []
              | Spice_review.Feature.File.Opaque _ ->
                  Some (path, 1))
          | None -> None))

(* Grammar-in-the-draft (11-review.md §CR compose): explicit CR/XCR text is
   parsed verbatim, a leading handle-colon addresses a recipient, and a bare
   body becomes [CR: body]. *)
let parse_draft draft =
  let trimmed = String.trim draft in
  let message error = Format.asprintf "%a" Spice_cr.Error.pp error in
  if String.equal trimmed "" then Error "the CR body must not be empty"
  else if
    String.starts_with ~prefix:"CR" trimmed
    || String.starts_with ~prefix:"XCR" trimmed
  then Result.map_error message (Spice_cr.parse trimmed)
  else
    let fallback () =
      Result.map_error message (Spice_cr.make ~body:trimmed ())
    in
    match String.index_opt trimmed ':' with
    | None -> fallback ()
    | Some i -> (
        let head = String.sub trimmed 0 i in
        let body = String.sub trimmed (i + 1) (String.length trimmed - i - 1) in
        match Spice_cr.Handle.of_string head with
        | Ok recipient ->
            Result.map_error message (Spice_cr.make ~recipient ~body ())
        | Error _ -> fallback ())

(* Two occurrences are the same CR when they share a path and comment-digest
   identity — the same key the review engine preserves a cursor across a refresh
   with. Line/column may shift as CRs are added or removed above, so they are not
   part of the identity. *)
let same_occurrence a b =
  Spice_path.Rel.equal
    (Spice_cr.Occurrence.path a)
    (Spice_cr.Occurrence.path b)
  && Spice_digest.Identity.equal
       (Spice_cr.Occurrence.digest a)
       (Spice_cr.Occurrence.digest b)

let occurrence_ordinal review index occurrence =
  let rec loop ordinal i = function
    | [] -> ordinal
    | _ when i >= index -> ordinal
    | candidate :: rest ->
        let ordinal =
          if same_occurrence occurrence candidate then ordinal + 1 else ordinal
        in
        loop ordinal (i + 1) rest
  in
  loop 0 0 (Spice_review.crs review)

let current_occurrence_by_ordinal review occurrence ordinal =
  let rec loop i = function
    | [] -> None
    | candidate :: rest ->
        if same_occurrence occurrence candidate then
          if Int.equal i ordinal then Some candidate else loop (i + 1) rest
        else loop i rest
  in
  loop 0 (Spice_review.crs review)

let compose_op review compose =
  match parse_draft (Review_compose.draft compose) with
  | Error _ as error -> error
  | Ok cr -> (
      match Review_compose.target compose with
      | Review_compose.Add { path; line } ->
          Ok (Spice_review.Op.Add { path; line; cr })
      | Review_compose.Edit { occurrence; ordinal }
      | Review_compose.Resolve { occurrence; ordinal } -> (
          (* Re-resolve the anchored occurrence against the CURRENT review: a
             background refresh may have reordered the CR list since the dialog
             opened, so replaying a bare index could rewrite a different CR.
             Duplicate identical CRs are disambiguated by their ordinal among
             path+digest matches at the time the dialog opened. A lost identity
             or ordinal means the CR changed on disk. *)
          match current_occurrence_by_ordinal review occurrence ordinal with
          | Some current ->
              Ok (Spice_review.Op.Replace { occurrence = current; cr })
          | None -> Error "CR changed on disk — review it again"))

(* Lock the live protocol and hand the mutation to the runtime, which re-verifies
   the on-disk fingerprint before writing. *)
let start_mutation screen ~notice op =
  match Spice_review.Live.fingerprint screen.live with
  | None ->
      notify screen ~text:"the review is refreshing; retry in a moment"
        ~warning:true
  | Some fingerprint -> (
      match Spice_review.Live.mutation_started screen.live ~fingerprint with
      | Error error ->
          notify screen
            ~text:(Format.asprintf "%a" Spice_review.Error.pp error)
            ~warning:true
      | Ok (live, request) ->
          ( Open { screen with live; pending_notice = Some notice },
            [
              Effect.Mutate
                {
                  request;
                  root = screen.root;
                  base = screen.base;
                  expected = fingerprint;
                  op;
                };
            ] ))

let map_compose t f =
  match t with
  | Open screen -> (
      match screen.panel.Review_panel.compose with
      | Some compose ->
          ( Open
              {
                screen with
                panel = Review_panel.set_compose screen.panel (Some (f compose));
              },
            [] )
      | None -> (t, []))
  | Loading _ | Failed _ -> (t, [])

(* {1 Update} *)

(* Every non-terminal message folds to [(t, Effect.t list)]; [stay] lifts that to
   the [Stay] event. The three terminal messages return [Close]/[Task_spice]. *)
let stay (t, effects) = (t, Stay effects)

let update msg t =
  match msg with
  | Close_pressed -> (t, Close (close_effects t))
  | Agent_requested ->
      (* Tasking spice hands over to chat: the shell flips the surface and
         submits on {!Task_spice}. The close bookkeeping runs first. *)
      (t, Task_spice (close_effects t))
  | Back -> (
      match t with
      | Open screen -> (
          match Review_panel.back screen.panel with
          | Some panel -> (Open { screen with panel }, Stay [])
          | None -> (t, Close (close_effects t)))
      | Loading _ | Failed _ -> (t, Close (close_effects t)))
  | Opened (request, result) -> (
      match t with
      | Loading { request = current; _ } when Int.equal current request -> (
          match result with
          | Error message -> stay (Failed message, [])
          | Ok opened ->
              let review =
                Spice_review.v ~feature:opened.ro_feature ~crs:opened.ro_crs
              in
              let review =
                match opened.ro_persisted with
                | Some record -> Spice_review.Persist.restore record review
                | None -> review
              in
              (* Land on the first file so space and enter act immediately;
                 a restored cursor keeps its position. *)
              let review =
                if
                  Spice_review.Cursor.equal
                    (Spice_review.cursor review)
                    Spice_review.Cursor.feature
                then Spice_review.move_cursor review Spice_review.Cursor.Next
                else review
              in
              stay
                ( Open
                    {
                      live =
                        Spice_review.Live.make ~review
                          ~fingerprint:opened.ro_fingerprint ();
                      root = opened.ro_root;
                      base = opened.ro_base;
                      range = opened.ro_range;
                      store_key = opened.ro_store_key;
                      resolver = opened.ro_resolver;
                      pending_notice = None;
                      panel = Review_panel.init;
                    },
                  [ Effect.Watch { root = opened.ro_root } ] ))
      | Loading _ | Failed _ | Open _ -> stay (t, []))
  | Fs_changed now -> (
      match t with
      | Open screen -> stay (live_step screen (Spice_review.Live.Fs_changed { now }))
      | Loading _ | Failed _ -> stay (t, []))
  | Tick (request, now) -> (
      match t with
      | Open screen ->
          stay (live_step screen (Spice_review.Live.Tick { now; request }))
      | Loading _ | Failed _ -> stay (t, []))
  | Loaded (request, result) -> (
      match t with
      | Open screen ->
          stay (live_step screen (Spice_review.Live.Loaded (request, result)))
      | Loading _ | Failed _ -> stay (t, []))
  | Watch_failed message -> (
      match t with
      | Open screen ->
          stay
            (notify screen
               ~text:("live refresh unavailable: " ^ message)
               ~warning:true)
      | Loading _ | Failed _ -> stay (t, []))
  | Moved move -> (
      match t with
      | Open screen ->
          let screen =
            { screen with panel = Review_panel.clear_notice screen.panel }
          in
          stay (set screen (Spice_review.move_cursor (screen_review screen) move))
      | Loading _ | Failed _ -> stay (t, []))
  | Line_moved direction -> (
      match t with
      | Open screen ->
          let screen =
            { screen with panel = Review_panel.clear_notice screen.panel }
          in
          stay (set screen (line_step (screen_review screen) direction))
      | Loading _ | Failed _ -> stay (t, []))
  | Hunk_jumped direction -> (
      match t with
      | Open screen ->
          let screen =
            { screen with panel = Review_panel.clear_notice screen.panel }
          in
          stay (set screen (hunk_jump (screen_review screen) direction))
      | Loading _ | Failed _ -> stay (t, []))
  | Focus_toggled -> (
      match t with
      | Open screen -> (
          let panel = Review_panel.toggle_focus screen.panel in
          let screen = { screen with panel } in
          match panel.Review_panel.depth with
          | Review_panel.Diff -> stay (set screen (seed_line (screen_review screen)))
          | Review_panel.Queue -> stay (Open screen, []))
      | Loading _ | Failed _ -> stay (t, []))
  | Nav_clicked cursor -> (
      match t with
      | Open screen -> (
          let screen =
            { screen with panel = Review_panel.clear_notice screen.panel }
          in
          match Spice_review.set_cursor (screen_review screen) cursor with
          | Ok review -> stay (set screen review)
          | Error _ -> stay (Open screen, []))
      | Loading _ | Failed _ -> stay (t, []))
  | Line_clicked scope -> (
      match t with
      | Open screen -> (
          let panel =
            Review_panel.clear_notice screen.panel |> fun panel ->
            match panel.Review_panel.depth with
            | Review_panel.Diff -> panel
            | Review_panel.Queue -> Review_panel.toggle_focus panel
          in
          let screen = { screen with panel } in
          match
            Spice_review.set_cursor (screen_review screen)
              (Spice_review.Cursor.Scope scope)
          with
          | Ok review -> stay (set screen review)
          | Error _ -> stay (Open screen, []))
      | Loading _ | Failed _ -> stay (t, []))
  | Entered -> (
      match t with
      | Open screen -> (
          match Review_panel.enter screen.panel (screen_review screen) with
          | Some panel ->
              let screen = { screen with panel } in
              stay (set screen (seed_line (screen_review screen)))
          | None -> stay (t, []))
      | Loading _ | Failed _ -> stay (t, []))
  | Space_pressed -> (
      match t with
      | Open screen -> (
          let review = screen_review screen in
          match space_scope review with
          | None -> stay (t, [])
          | Some scope ->
              if Spice_review.is_reviewed review scope then
                stay
                  (match Spice_review.mark_unreviewed review scope with
                  | Ok review' -> set ~save:true screen review'
                  | Error error ->
                      notify screen
                        ~text:(Format.asprintf "%a" Spice_review.Error.pp error)
                        ~warning:true)
              else
                stay
                  (match Spice_review.mark_reviewed review scope with
                  | Ok review' ->
                      (* Advance lands on the next stop — a hunk or file scope —
                         and seeding turns it into that unit's first changed
                         line, so the next hunk is visibly selected. *)
                      let review' =
                        seed_line
                          (Spice_review.move_cursor review'
                             Spice_review.Cursor.Next)
                      in
                      set ~save:true screen review'
                  | Error error ->
                      notify screen
                        ~text:(Format.asprintf "%a" Spice_review.Error.pp error)
                        ~warning:true))
      | Loading _ | Failed _ -> stay (t, []))
  | Verdict_toggled -> (
      match t with
      | Open screen ->
          let review = screen_review screen in
          let review' =
            match Spice_review.verdict_freshness review with
            | `Approved -> Spice_review.set_pending review
            | `Pending | `Stale -> Spice_review.approve review
          in
          stay (set ~save:true screen review')
      | Loading _ | Failed _ -> stay (t, []))
  | Help_toggled -> (
      match t with
      | Open screen ->
          stay (Open { screen with panel = Review_panel.toggle_help screen.panel }, [])
      | Loading _ | Failed _ -> stay (t, []))
  | Context_toggled -> (
      match t with
      | Open screen ->
          stay
            (Open { screen with panel = Review_panel.toggle_context screen.panel }, [])
      | Loading _ | Failed _ -> stay (t, []))
  | Save_failed message -> (
      match t with
      | Open screen ->
          stay
            (notify screen
               ~text:("could not save review state: " ^ message)
               ~warning:true)
      | Loading _ | Failed _ -> stay (t, []))
  | Compose_started kind -> (
      match t with
      | Open screen -> (
          let review = screen_review screen in
          let set_compose compose =
            ( Open
                {
                  screen with
                  panel = Review_panel.set_compose screen.panel (Some compose);
                },
              [] )
          in
          match kind with
          | `Add -> (
              match add_anchor review with
              | Some (path, line) ->
                  stay
                    (set_compose
                       (Review_compose.make
                          ~target:(Review_compose.Add { path; line })
                          ~draft:""))
              | None ->
                  stay
                    (notify screen ~text:"nothing to comment on here"
                       ~warning:false))
          | `Edit -> (
              match cursor_cr review with
              | Some (index, occ) ->
                  let ordinal = occurrence_ordinal review index occ in
                  let draft =
                    match Spice_cr.Occurrence.comment occ with
                    | Ok cr -> Spice_cr.to_string cr
                    | Error _ -> String.trim (Spice_cr.Occurrence.raw occ)
                  in
                  stay
                    (set_compose
                       (Review_compose.make
                          ~target:
                            (Review_compose.Edit { occurrence = occ; ordinal })
                          ~draft))
              | None ->
                  stay (notify screen ~text:"select a CR to edit" ~warning:false))
          | `Resolve -> (
              match cursor_cr review with
              | Some (index, occ) -> (
                  match Spice_cr.Occurrence.comment occ with
                  | Ok cr -> (
                      let ordinal = occurrence_ordinal review index occ in
                      let resolver =
                        match Spice_cr.Handle.of_string screen.resolver with
                        | Ok handle -> handle
                        | Error _ -> (
                            match Spice_cr.Handle.of_string "user" with
                            | Ok handle -> handle
                            | Error _ -> assert false)
                      in
                      match Spice_cr.resolve ~resolver cr with
                      | Ok resolved ->
                          stay
                            (set_compose
                               (Review_compose.make
                                  ~target:
                                    (Review_compose.Resolve
                                       { occurrence = occ; ordinal })
                                  ~draft:(Spice_cr.to_string resolved)))
                      | Error error ->
                          stay
                            (notify screen
                               ~text:(Format.asprintf "%a" Spice_cr.Error.pp error)
                               ~warning:true))
                  | Error _ ->
                      stay
                        (notify screen
                           ~text:
                             "a malformed CR cannot be resolved; edit or remove it"
                           ~warning:true))
              | None ->
                  stay
                    (notify screen ~text:"select a CR to resolve" ~warning:false)))
      | Loading _ | Failed _ -> stay (t, []))
  | Compose_char c -> stay (map_compose t (fun compose -> Review_compose.append compose c))
  | Compose_backspace -> stay (map_compose t Review_compose.backspace)
  | Compose_cancelled -> (
      match t with
      | Open screen ->
          stay
            (Open { screen with panel = Review_panel.set_compose screen.panel None }, [])
      | Loading _ | Failed _ -> stay (t, []))
  | Compose_submitted -> (
      match t with
      | Open screen -> (
          match screen.panel.Review_panel.compose with
          | None -> stay (t, [])
          | Some compose -> (
              let review = screen_review screen in
              match compose_op review compose with
              | Error problem ->
                  stay
                    (map_compose (Open screen) (fun compose ->
                         Review_compose.with_problem compose problem))
              | Ok op ->
                  let notice =
                    match Review_compose.target compose with
                    | Review_compose.Add _ -> "CR added"
                    | Review_compose.Edit _ -> "CR updated"
                    | Review_compose.Resolve _ -> "CR resolved"
                  in
                  stay (start_mutation screen ~notice op)))
      | Loading _ | Failed _ -> stay (t, []))
  | Remove_requested -> (
      match t with
      | Open screen -> (
          match cursor_cr (screen_review screen) with
          | Some (_, occurrence) ->
              stay
                (start_mutation screen ~notice:"CR removed"
                   (Spice_review.Op.Remove { occurrence }))
          | None ->
              stay (notify screen ~text:"select a CR to remove" ~warning:false))
      | Loading _ | Failed _ -> stay (t, []))
  | Mutated (request, result) -> (
      match t with
      | Open screen -> (
          let live, outcome =
            Spice_review.Live.mutation_loaded screen.live request result
          in
          let screen = { screen with live } in
          match outcome with
          | `Stale ->
              (* The worktree moved under the edit/resolve/remove (11-review.md
                 §States "Refresh mid-composition"): say so and keep the draft —
                 [with_problem] leaves it intact — so the reviewer re-targets it,
                 mirroring the [`Failed] fold. *)
              let stale = "CR changed on disk — review it again" in
              let panel =
                match screen.panel.Review_panel.compose with
                | Some compose ->
                    Review_panel.set_compose screen.panel
                      (Some (Review_compose.with_problem compose stale))
                | None ->
                    Review_panel.set_notice screen.panel ~text:stale ~warning:true
              in
              stay (Open { screen with panel; pending_notice = None }, [])
          | `Failed message ->
              let panel =
                match screen.panel.Review_panel.compose with
                | Some compose ->
                    Review_panel.set_compose screen.panel
                      (Some (Review_compose.with_problem compose message))
                | None ->
                    Review_panel.set_notice screen.panel ~text:message
                      ~warning:true
              in
              stay (Open { screen with panel; pending_notice = None }, [])
          | `Replaced review ->
              let notice =
                Option.value screen.pending_notice ~default:"CR written"
              in
              let panel =
                Review_panel.set_notice
                  (Review_panel.set_compose screen.panel None)
                  ~text:notice ~warning:false
              in
              stay
                ( Open { screen with panel; pending_notice = None },
                  [
                    Effect.Store
                      {
                        root = screen.root;
                        key = screen.store_key;
                        record = Spice_review.Persist.of_review review;
                      };
                  ] ))
      | Loading _ | Failed _ -> stay (t, []))

(* {1 Keyboard} *)

let plain_text_key (data : Key.event) =
  let modifier = data.Key.modifier in
  (not modifier.Modifier.ctrl)
  && (not modifier.Modifier.alt)
  && not modifier.Modifier.super

let ctrl_o_char data c =
  data.Key.modifier.Modifier.ctrl
  && (Uchar.equal c (Uchar.of_char 'o') || Uchar.equal c (Uchar.of_char 'O'))
  || Uchar.equal c (Uchar.of_int 0x0f)

let ctrl_p_char data c =
  data.Key.modifier.Modifier.ctrl
  && (Uchar.equal c (Uchar.of_char 'p') || Uchar.equal c (Uchar.of_char 'P'))
  || Uchar.equal c (Uchar.of_int 0x10)

let ctrl_n_char data c =
  data.Key.modifier.Modifier.ctrl
  && (Uchar.equal c (Uchar.of_char 'n') || Uchar.equal c (Uchar.of_char 'N'))
  || Uchar.equal c (Uchar.of_int 0x0e)

(* The UTF-8 encoding of a printable, for the painted compose draft. *)
let utf8_of_uchar u =
  let buffer = Buffer.create 4 in
  Buffer.add_utf_8_uchar buffer u;
  Buffer.contents buffer

let key t (data : Key.event) : msg option =
  let char_is ch c = Uchar.equal c (Uchar.of_char ch) in
  let composing =
    match t with
    | Open screen -> Option.is_some screen.panel.Review_panel.compose
    | Loading _ | Failed _ -> false
  in
  if composing then
    (* The compose dialog's app-owned input: printables and backspace fold into
       the draft; esc cancels; enter submits. No key escapes to a native widget
       (the screen owns its keyboard), so there is no passthrough. *)
    match data.Key.key with
    | Key.Escape -> Some Compose_cancelled
    | Key.Enter | Key.Line_feed | Key.KP_enter -> Some Compose_submitted
    | Key.Backspace -> Some Compose_backspace
    | Key.Char c when plain_text_key data -> Some (Compose_char (utf8_of_uchar c))
    | _ -> None
  else
    (* Movement is focus-aware: the nav steps review units, the diff pane steps
       lines with ]/[ jumping hunks. *)
    let diff_focused =
      match t with
      | Open screen -> (
          match screen.panel.Review_panel.depth with
          | Review_panel.Diff -> true
          | Review_panel.Queue -> false)
      | Loading _ | Failed _ -> false
    in
    let step_next =
      if diff_focused then Line_moved `Next else Moved Spice_review.Cursor.Next
    in
    let step_previous =
      if diff_focused then Line_moved `Previous
      else Moved Spice_review.Cursor.Previous
    in
    match data.Key.key with
    | Key.Escape -> (
        match t with
        | Open screen when screen.panel.Review_panel.help -> Some Help_toggled
        | Open _ -> Some Back
        | Loading _ | Failed _ -> Some Close_pressed)
    | Key.Up -> Some step_previous
    | Key.Down -> Some step_next
    | Key.Char c when ctrl_p_char data c -> Some step_previous
    | Key.Char c when ctrl_n_char data c -> Some step_next
    | Key.Char c when ctrl_o_char data c -> Some Context_toggled
    | Key.Tab -> Some Focus_toggled
    | Key.Enter | Key.Line_feed | Key.KP_enter -> Some Entered
    | Key.Home -> Some (Moved Spice_review.Cursor.First)
    | Key.End -> Some (Moved Spice_review.Cursor.Last)
    (* No pane holds a page's worth of hidden rows to scroll — the nav windows on
       the cursor and the diff auto-reveals it — so a page key steps the cursor
       (a unit in nav, a line in the diff), the focus-aware move the arrows make. *)
    | Key.Page_up -> Some step_previous
    | Key.Page_down -> Some step_next
    | Key.Char c when plain_text_key data ->
        if char_is ' ' c then Some Space_pressed
        else if char_is 'j' c then Some step_next
        else if char_is 'k' c then Some step_previous
        else if char_is 'n' c then Some (Moved Spice_review.Cursor.Next_cr)
        else if char_is 'p' c then Some (Moved Spice_review.Cursor.Previous_cr)
        else if char_is 'g' c then Some (Moved Spice_review.Cursor.First)
        else if char_is 'G' c then Some (Moved Spice_review.Cursor.Last)
        else if char_is ']' c then Some (Hunk_jumped `Next)
        else if char_is '[' c then Some (Hunk_jumped `Previous)
        else if char_is 'a' c then Some Verdict_toggled
        else if char_is 't' c then Some Agent_requested
        else if char_is '?' c then Some Help_toggled
        else if char_is 'c' c then Some (Compose_started `Add)
        else if char_is 'e' c then Some (Compose_started `Edit)
        else if char_is 'x' c then Some (Compose_started `Resolve)
        else if char_is 'd' c then Some Remove_requested
        else None
    | _ -> None

(* {1 View} *)

let view ?width ?height ~inject t =
  match t with
  | Loading _ -> Review_panel.loading_view ?width ?height ()
  | Failed message -> Review_panel.error_view ?width ?height ~message ()
  | Open screen ->
      Review_panel.view ?width ?height ~range:screen.range
        ~on_click:(fun cursor -> inject (Nav_clicked cursor))
        ~on_line_click:(fun scope -> inject (Line_clicked scope))
        screen.panel (screen_review screen)
