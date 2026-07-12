(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
module Access = Spice_permission.Access
module Request = Spice_permission.Request
module Review = Spice_permission.Policy.Review
module Suggest = Spice_permission.Suggest
module Requested = Spice_session.Permission.Requested

type scope = Session | User

type t = {
  request : Requested.t;
  nav : Option_list.t;
  expanded : bool;
  suggestions : Suggest.t list;
  scope : scope;
}

(* The always-allow option is present only when at least one reviewed access has
   a family generalization; otherwise the dialog keeps its three options. *)
let has_always t = t.suggestions <> []
let option_count t = if has_always t then 4 else 3

let make request =
  let suggestions =
    Suggest.of_accesses (Review.accesses (Requested.review request))
  in
  {
    request;
    nav = Option_list.make ~count:(if suggestions = [] then 3 else 4);
    expanded = false;
    suggestions;
    scope = Session;
  }

type outcome =
  | Stay
  | Allow of Review.scope
  | Always of { rules : Spice_permission.Policy.Rule.t list; scope : scope }
  | Deny

(* --- Access facts, ported from the old TUI permission prompt --- *)

let path_op_string = function
  | `Read -> "read"
  | `Create -> "create"
  | `Modify -> "modify"
  | `Delete -> "delete"

let kind_string = function
  | `Read -> "read"
  | `Write -> "write"
  | `Command -> "command"
  | `Network -> "network"
  | `Custom -> "custom"

let workspace_display ~root_key ~relative =
  match Spice_path.Rel.to_string relative with
  | "" -> root_key
  | relative -> root_key ^ "/" ^ relative

let scope_display = function
  | Access.Path_scope.Workspace { root_key; relative } ->
      workspace_display
        ~root_key:(Spice_workspace.Root.Key.to_string root_key)
        ~relative
  | Access.Path_scope.Outside_workspace path -> Spice_path.Abs.to_string path
  | Access.Path_scope.Unknown path -> path

(* The short display path: root-relative for a workspace path, else the full
   display. Used in headlines and the exact-grant scope label. *)
let short_path = function
  | Access.Path_scope.Workspace { root_key; relative } -> (
      match Spice_path.Rel.to_string relative with
      | "" -> Spice_workspace.Root.Key.to_string root_key
      | r -> r)
  | (Access.Path_scope.Outside_workspace _ | Access.Path_scope.Unknown _) as
    scope ->
      scope_display scope

let protocol_string = function
  | `Http -> "http"
  | `Https -> "https"
  | `Ssh -> "ssh"
  | `Tcp -> "tcp"
  | `Udp -> "udp"
  | `Other name -> name

let shell_arg = Filename.quote

let access_text access =
  match (access : Access.t) with
  | Access.Path { op; scope } ->
      kind_string (Access.kind access)
      ^ " " ^ path_op_string op ^ " " ^ scope_display scope
  | Access.Command (Access.Command.Shell { text; cwd; _ }) ->
      "command " ^ shell_arg text ^ " in " ^ scope_display cwd
  | Access.Command (Access.Command.Argv { program; args; cwd; _ }) ->
      "exec "
      ^ String.concat " " (List.map shell_arg (program :: args))
      ^ " in " ^ scope_display cwd
  | Access.Command (Access.Command.Code { language; source; cwd; _ }) ->
      "evaluate " ^ language ^ " " ^ shell_arg source ^ " in "
      ^ scope_display cwd
  | Access.Network { protocol; host; port } ->
      "network " ^ protocol_string protocol ^ "://" ^ host
      ^ Option.fold ~none:"" ~some:(fun p -> ":" ^ string_of_int p) port
  | Access.Custom { name; subject } ->
      "custom " ^ name
      ^ Option.fold ~none:"" ~some:(fun s -> " " ^ shell_arg s) subject

let is_path = function
  | Access.Path _ -> true
  | Access.Command _ | Access.Network _ | Access.Custom _ -> false

let path_verb = function
  | `Read -> "Read"
  | `Create -> "Create"
  | `Modify -> "Edit"
  | `Delete -> "Delete"

let access_headline = function
  | Access.Path { op; scope } -> path_verb op ^ " " ^ short_path scope ^ "?"
  | Access.Command _ -> "Run a shell command?"
  | Access.Network { host; _ } -> "Connect to " ^ host ^ "?"
  | Access.Custom { name; _ } -> "Allow " ^ name ^ "?"

let headline = function
  | [ access ] -> access_headline access
  | accesses ->
      if List.for_all is_path accesses then
        Printf.sprintf "Apply a patch to %d files?" (List.length accesses)
      else Printf.sprintf "Approve %d operations?" (List.length accesses)

(* The exact-grant scope for option 2's honest label: it names only what an
   identical [Access.t] re-approves — the same edit target, command, or host,
   never a broader family (doc/manual/security.md). *)
let access_scope = function
  | Access.Path { op; scope } ->
      let noun =
        match op with
        | `Read -> "reads of "
        | `Create | `Modify -> "edits to "
        | `Delete -> "deletes of "
      in
      noun ^ short_path scope
  | Access.Command _ -> "this command"
  | Access.Network { host; _ } -> "connections to " ^ host
  | Access.Custom { name; _ } -> name

let session_scope = function
  | [ access ] -> access_scope access
  | accesses when List.for_all is_path accesses -> "these edits"
  | _ -> "these accesses"

let primary_allow_once = function
  | [ Access.Command _ ] -> "run it once"
  | [ Access.Path { op = `Create | `Modify | `Delete; _ } ] -> "apply this edit"
  | accesses when List.length accesses > 1 && List.for_all is_path accesses ->
      "apply all"
  | _ -> "allow once"

let command_access = function
  | Access.Command (Access.Command.Shell { text; cwd; _ }) ->
      Some (text, Some (scope_display cwd))
  | Access.Command (Access.Command.Argv { program; args; cwd; _ }) ->
      Some
        ( String.concat " " (List.map shell_arg (program :: args)),
          Some (scope_display cwd) )
  | Access.Command (Access.Command.Code { language; source; cwd; _ }) ->
      Some (language ^ " " ^ shell_arg source, Some (scope_display cwd))
  | Access.Path _ | Access.Network _ | Access.Custom _ -> None

(* --- Change metadata (diff + counts) --- *)

let request_data t = Requested.request t.request
let reviewed_accesses t = Review.accesses (Requested.review t.request)

let change_for_access t access =
  match Request.changes_for_access (request_data t) access with
  | change :: _ -> Some change
  | [] -> None

let access_counts t access =
  match change_for_access t access with
  | None -> (0, 0)
  | Some change ->
      ( Option.value ~default:0 (Request.Change.additions change),
        Option.value ~default:0 (Request.Change.removals change) )

let total_counts t accesses =
  List.fold_left
    (fun (a, r) access ->
      let da, dr = access_counts t access in
      (a + da, r + dr))
    (0, 0) accesses

let has_diff t accesses =
  List.exists
    (fun access ->
      match change_for_access t access with
      | Some change -> Option.is_some (Request.Change.diff change)
      | None -> false)
    accesses

(* --- Keys --- *)

let letter (ev : Matrix.Input.Key.event) c =
  (not ev.Matrix.Input.Key.modifier.Matrix.Input.Modifier.ctrl)
  &&
  match ev.Matrix.Input.Key.key with
  | Matrix.Input.Key.Char u -> Uchar.equal u (Uchar.of_char c)
  | _ -> false

let ctrl_o (ev : Matrix.Input.Key.event) =
  ev.Matrix.Input.Key.modifier.Matrix.Input.Modifier.ctrl
  &&
  match ev.Matrix.Input.Key.key with
  | Matrix.Input.Key.Char u -> Uchar.equal u (Uchar.of_char 'o')
  | _ -> false

let next_scope = function Session -> User | User -> Session

let always_outcome t =
  Always { rules = List.map Suggest.rule t.suggestions; scope = t.scope }

(* Deny keeps its [3] so existing muscle memory and tests hold; always-allow is
   appended as [4] and is inert when no family rule can be derived. *)
let resolve t = function
  | 0 -> Allow Review.Once
  | 1 -> Allow Review.Session
  | 2 -> Deny
  | 3 when has_always t -> always_outcome t
  | _ -> Deny

let key ev t =
  if ctrl_o ev then ({ t with expanded = not t.expanded }, Stay)
  else if letter ev 'y' then (t, Allow Review.Once)
  else if letter ev 'a' then (t, Allow Review.Session)
  else if letter ev 'd' || letter ev 'n' then (t, Deny)
  else if letter ev 's' && has_always t then
    ({ t with scope = next_scope t.scope }, Stay)
  else
    match Panel.classify ev with
    | Panel.Digit d when d >= 1 && d <= option_count t -> (t, resolve t (d - 1))
    | Panel.Digit _ -> (t, Stay)
    | Panel.Action Panel.Up -> ({ t with nav = Option_list.up t.nav }, Stay)
    | Panel.Action Panel.Down -> ({ t with nav = Option_list.down t.nav }, Stay)
    | Panel.Action Panel.Enter -> (t, resolve t (Option_list.selected t.nav))
    | Panel.Action Panel.Escape -> (t, Deny)
    | Panel.Printable _ | Panel.Action _ -> (t, Stay)

let summary t =
  let accesses = reviewed_accesses t in
  let head = headline accesses in
  match accesses with
  | [ access ] -> (
      match command_access access with
      | Some (command, _) -> head ^ "  $ " ^ command
      | None -> head)
  | _ -> head

let scope_label t = session_scope (reviewed_accesses t)

(* --- View --- *)

let indent = padding_lrtb 2 2 0 0
let blank = box ~flex_shrink:0. ~size:{ width = pct 100; height = px 1 } []
let dim s = text ~style:Theme.muted ~wrap:`Word s
let max_diff_lines = 16

(* [Change.diff] is a rendered unified diff. Colour each line by its role and
   cap the window so the option list stays visible; ctrl+o expands. *)
let diff_view ~expanded diff =
  let lines = String.split_on_char '\n' diff in
  let total = List.length lines in
  let shown =
    if expanded then lines
    else List.filteri (fun i _ -> i < max_diff_lines) lines
  in
  let style line =
    if String.length line = 0 then Theme.muted
    else
      match line.[0] with
      | '+' -> Theme.success
      | '-' -> Theme.error
      | '@' -> Theme.faint
      | _ -> Theme.muted
  in
  let rows =
    List.map (fun line -> text ~style:(style line) ~wrap:`None line) shown
  in
  let rows =
    if (not expanded) && total > max_diff_lines then
      rows
      @ [
          text ~style:Theme.faint ~wrap:`None
            (Printf.sprintf "… %d more line%s (ctrl+o expands)"
               (total - max_diff_lines)
               (if total - max_diff_lines = 1 then "" else "s"));
        ]
    else rows
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0. ~padding:indent rows

let command_view command cwd =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0. ~padding:indent
    (text ~style:Theme.warning ~wrap:`None ("$ " ^ command)
    :: (match cwd with None -> [] | Some cwd -> [ dim ("in " ^ cwd) ]))

let single_preview ~expanded t access =
  match (change_for_access t access, command_access access) with
  | Some change, _ when Option.is_some (Request.Change.diff change) ->
      diff_view ~expanded (Option.get (Request.Change.diff change))
  | _, Some (command, cwd) -> command_view command cwd
  | (Some _ | None), None ->
      box ~padding:indent ~flex_shrink:0. [ dim (access_text access) ]

let list_preview t accesses =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0. ~padding:indent
    (List.map
       (fun access ->
         let additions, removals = access_counts t access in
         let label =
           match access with
           | Access.Path { scope; _ } -> short_path scope
           | _ -> access_text access
         in
         let counts =
           if additions = 0 && removals = 0 then []
           else
             [
               text ~style:Theme.success ~wrap:`None
                 (Printf.sprintf "  +%d " additions);
               text ~style:Theme.error ~wrap:`None
                 (Printf.sprintf "−%d" removals);
             ]
         in
         box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
           (text ~style:Theme.muted ~wrap:`None label :: counts))
       accesses)

let preview_view ~expanded t accesses =
  match accesses with
  | [ access ] -> [ single_preview ~expanded t access ]
  | accesses -> [ list_preview t accesses ]

let counts_seg (additions, removals) =
  if additions = 0 && removals = 0 then []
  else
    [
      box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
        [
          text ~style:Theme.success ~wrap:`None
            (Printf.sprintf "+%d " additions);
          text ~style:Theme.error ~wrap:`None (Printf.sprintf "−%d" removals);
        ];
    ]

let headline_row ~counts head =
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0. ~padding:indent
    ~justify_content:Justify.Space_between
    ~size:{ width = pct 100; height = auto }
    (text ~style:Theme.accent ~wrap:`None head :: counts_seg counts)

let scope_word = function
  | Session -> "this session"
  | User -> "all your projects"

let always_summary t =
  String.concat ", " (List.map Suggest.summary t.suggestions)

let options_view t ~allow_once ~session_scope =
  let line ~selected s =
    text ~style:(if selected then Theme.accent else Theme.muted) ~wrap:`Word s
  in
  let simple =
    [|
      "Yes, " ^ allow_once;
      "Yes, don't ask again for " ^ session_scope ^ " this session";
      "No, and tell Spice what to do differently";
    |]
  in
  (* The always row carries a second dim line naming where the rule saves and
     that [s] cycles the scope, so the derived rule and its destination are
     visible before the reviewer confirms it. *)
  let always ~selected =
    box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
      [
        line ~selected ("Yes, always allow " ^ always_summary t);
        text ~style:Theme.faint ~wrap:`Word
          ("saves for " ^ scope_word t.scope ^ " — press s to change");
      ]
  in
  let label i ~selected =
    if i < 3 then line ~selected simple.(i) else always ~selected
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    (List.init (option_count t) (fun i ->
         let selected = Option_list.selected t.nav = i in
         Option_list.row ~selected ~number:(i + 1) ~label:(label i ~selected) ()))

let view ~width t =
  let accesses = reviewed_accesses t in
  let counts = total_counts t accesses in
  let allow_once = primary_allow_once accesses in
  let session_scope = session_scope accesses in
  let content =
    headline_row ~counts (headline accesses)
    :: blank
    :: preview_view ~expanded:t.expanded t accesses
    @ [ blank; options_view t ~allow_once ~session_scope ]
  in
  let hint =
    [ (if has_always t then "1-4 choose" else "1/2/3 choose"); "enter confirm" ]
    @ (if has_always t then [ "s scope" ] else [])
    @ (if has_diff t accesses && not t.expanded then [ "ctrl+o expand" ] else [])
    @ [ "esc deny with feedback" ]
  in
  (* The top rule is accent, not the plain [rule] gray: a decision dialog is
     spice asking, and the accent rule is its single piece of chrome (07-dialogs
     §Shared anatomy, §Theme usage; 00-overview §One rule idiom). *)
  Panel.view ~frame:Theme.color_accent ~name:"permission" ~filter:"" ~hint
    ~width ~content
