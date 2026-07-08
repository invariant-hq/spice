(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Canonical product projection and eliminators for run-state waiting.

   Both cli_session and cli_run render [Spice_session.Waiting.t]
   exclusively through this module, so the JSON waiting object, the human
   fact line, and the continuation commands cannot diverge between the
   [session show] and [run] surfaces. *)

open Cli_common
module Session = Spice_session
module Tool_call = Spice_llm.Tool.Call

type phase = Session.Run.Phase.t =
  | Idle
  | Waiting of Session.Waiting.t
  | Active

let phase = Session.Run.phase
let phase_string = Session.Run.Phase.to_string

(* One classification path for question waits: a valid [ask_user] payload is
   the question text; an invalid one still surfaces as an answerable question
   describing the decode failure. Other host tools are not questions. *)
let question_text call =
  Option.bind
    (Spice_protocol.Call.classify call)
    Spice_protocol.Call.answerable_question

(* A plan proposal boundary classifies through the same path; an invalid
   [propose_plan] payload is not a plan the surface can render or resolve, so it
   falls back to the generic host-tool line. *)
let plan_proposal call =
  Option.bind
    (Spice_protocol.Call.classify call)
    Spice_protocol.Call.plan_proposal

(* The fact part of the human line, after the phase token. [cli_session]
   prefixes a possibly lifecycle-decorated token ("waiting (archived): ");
   [human] is the canonical full line for surfaces without decoration. *)
let facts block =
  let call = Session.Waiting.call block in
  match block with
  | Session.Waiting.Permission request ->
      "permission "
      ^ Session.Permission.Id.to_string
          (Session.Permission.Requested.id request)
      ^ " tool=" ^ Tool_call.name call ^ " turn="
      ^ Session.Turn.Id.to_string (Session.Permission.Requested.turn request)
      ^ " call=" ^ Tool_call.id call
  | Session.Waiting.Host_tool _ -> (
      match question_text call with
      | Some question ->
          "user question call=" ^ Tool_call.id call ^ " question="
          ^ Filename.quote question
      | None -> (
          match plan_proposal call with
          | Some proposal ->
              let id =
                Spice_protocol.Plan.Id.to_string
                  (Spice_protocol.Plan.Proposal.id proposal)
              in
              let title =
                match Spice_protocol.Plan.Proposal.title proposal with
                | Some title -> " title=" ^ Filename.quote title
                | None -> ""
              in
              "plan " ^ id ^ " call=" ^ Tool_call.id call ^ title
          | None ->
              "host tool " ^ Tool_call.name call ^ " call=" ^ Tool_call.id call)
      )
  | Session.Waiting.Tool_claim execution ->
      "unfinished tool claim "
      ^ Session.Tool_claim.Id.to_string
          (Session.Tool_claim.Started.id execution)
      ^ " tool=" ^ Tool_call.name call ^ " turn="
      ^ Session.Turn.Id.to_string (Session.Tool_claim.Started.turn execution)
      ^ " call=" ^ Tool_call.id call

let human block = "waiting: " ^ facts block

(* Plan prompt detail: the proposed plan's id, title, and a bounded body
   preview, shown beneath the waiting line the way permission blocks show their
   access detail. [] for any host-tool wait that is not a plan proposal. *)
let plan_body_preview_lines = 24

let plan_lines block =
  match block with
  | Session.Waiting.Permission _ | Session.Waiting.Tool_claim _ -> []
  | Session.Waiting.Host_tool _ -> (
      match plan_proposal (Session.Waiting.call block) with
      | None -> []
      | Some proposal ->
          let header =
            match Spice_protocol.Plan.Proposal.title proposal with
            | Some title ->
                "plan "
                ^ Spice_protocol.Plan.Id.to_string
                    (Spice_protocol.Plan.Proposal.id proposal)
                ^ ": " ^ title
            | None ->
                "plan "
                ^ Spice_protocol.Plan.Id.to_string
                    (Spice_protocol.Plan.Proposal.id proposal)
          in
          let body_lines =
            String.split_on_char '\n'
              (Spice_protocol.Plan.Proposal.body proposal)
          in
          let preview, truncated =
            if List.length body_lines > plan_body_preview_lines then
              ( List.filteri (fun i _ -> i < plan_body_preview_lines) body_lines,
                true )
            else (body_lines, false)
          in
          (header :: "plan:" :: List.map (fun line -> "    " ^ line) preview)
          @ if truncated then [ "    …" ] else [])

(* Permission prompt detail: the render-time provenance and evidence shared
   by waiting text, waiting JSON, status JSON, and the permission.requested
   event. Provenance is computed against the same effective policy the run
   uses — the rule table plus the workflow-mode contract — so the explanation
   matches the decision; it is honest about config changes since the block.
   Contract rules are not table rows, so they label as "workflow contract"
   rather than with a rule id. *)

module Permission_run = Spice_host.Permission.Run
module Access = Spice_permission.Access
module Policy = Spice_permission.Policy

type permission_context = {
  permission : Cli_common.permission_args;
  policy : Policy.t;
  grants : Policy.Grants.t;
}

let permission_context (permission : Cli_common.permission_args) ~workflow_mode
    state =
  {
    permission;
    policy =
      Spice_protocol.Contract.policy
        (Spice_protocol.Mode.contract workflow_mode)
        ~configured:(Permission_run.policy permission);
    grants = Session.State.grants state;
  }

let kind_string = function
  | `Read -> "read"
  | `Write -> "write"
  | `Command -> "command"
  | `Network -> "network"
  | `Custom -> "custom"

let path_op_string = function
  | `Read -> "read"
  | `Create -> "create"
  | `Modify -> "modify"
  | `Delete -> "delete"

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

let protocol_string = function
  | `Http -> "http"
  | `Https -> "https"
  | `Ssh -> "ssh"
  | `Tcp -> "tcp"
  | `Udp -> "udp"
  | `Other name -> name

(* cwd is permission identity (two commands differing only in cwd need
   separate approvals), so the prompt must show it. The workspace root is the
   default and stays implicit. *)
let cwd_text = function
  | None -> ""
  | Some (Access.Path_scope.Workspace { relative; _ })
    when Spice_path.Rel.equal relative Spice_path.Rel.root ->
      ""
  | Some scope -> " (in " ^ scope_display scope ^ ")"

let access_text access =
  match (access : Access.t) with
  | Access.Path { op; scope } ->
      kind_string (Access.kind access)
      ^ " " ^ path_op_string op ^ " " ^ scope_display scope
  | Access.Command (Access.Command.Shell { text; cwd }) ->
      "command shell " ^ shell_arg text ^ cwd_text cwd
  | Access.Command (Access.Command.Argv { program; args; cwd }) ->
      "command exec "
      ^ String.concat " " (List.map shell_arg (program :: args))
      ^ cwd_text cwd
  | Access.Network { protocol; host; port } -> (
      "network " ^ protocol_string protocol ^ "://" ^ host
      ^ match port with None -> "" | Some port -> ":" ^ string_of_int port)
  | Access.Custom { kind; name; subject } -> (
      kind_string kind ^ " custom " ^ name
      ^
      match subject with
      | None -> ""
      | Some subject -> " " ^ shell_arg subject)

let rule_row context rule = Permission_run.find context.permission rule

let rule_label context rule =
  match rule_row context rule with
  | Some row ->
      "rule " ^ row.Permission_run.id ^ " ("
      ^ source_kind_string row.Permission_run.source
      ^ ")"
  | None -> "workflow contract"

let explanation context access =
  Policy.explain ~grants:context.grants context.policy access

let explanation_label context = function
  | Policy.Needs_review -> "review: no rule or grant"
  | Policy.Needs_review_by_rule rule -> "review: " ^ rule_label context rule
  | Policy.Denied_by_rule rule -> "deny: " ^ rule_label context rule
  | Policy.Allowed_by_rule rule -> "allow: " ^ rule_label context rule
  | Policy.Allowed_by_grant -> "allow: session grant"

(* The one projection both the text and JSON renderers consume: same
   accesses, same explanations, same change metadata, by construction. *)
type reviewed = {
  access : Access.t;
  explanation : Policy.explanation;
  change : Spice_permission.Request.Change.t option;
}

let reviewed context request =
  Session.Permission.Requested.review request
  |> Spice_permission.Policy.Review.items
  |> List.map (fun item ->
      let access = Spice_permission.Request.Item.access item in
      {
        access;
        explanation = explanation context access;
        change = Spice_permission.Request.Item.change item;
      })

let change_counts change =
  let part prefix = Option.map (fun n -> prefix ^ string_of_int n) in
  match
    List.filter_map Fun.id
      [
        part "+" (Spice_permission.Request.Change.additions change);
        part "-" (Spice_permission.Request.Change.removals change);
      ]
  with
  | [] -> ""
  | parts -> " (" ^ String.concat " " parts ^ ")"

let permission_lines context request =
  let reviewed = reviewed context request in
  let reviewed_accesses =
    Session.Permission.Requested.review request
    |> Spice_permission.Policy.Review.accesses
  in
  let access_lines =
    List.map
      (fun access ->
        "- " ^ access_text access ^ "  ["
        ^ explanation_label context (explanation context access)
        ^ "]")
      reviewed_accesses
  in
  let change_lines =
    List.concat_map
      (fun { access; change; _ } ->
        match change with
        | None -> []
        | Some change ->
            ("- " ^ access_text access ^ change_counts change)
            ::
            (match Spice_permission.Request.Change.diff change with
            | None -> []
            | Some diff ->
                let lines = String.split_on_char '\n' diff in
                let lines =
                  (* A trailing newline in the rendered diff would print a
                     whitespace-only indent line. *)
                  match List.rev lines with
                  | "" :: rest -> List.rev rest
                  | _ -> lines
                in
                List.map (fun line -> "    " ^ line) lines))
      reviewed
  in
  ("mode: "
  ^ Spice_host.Permission.Preset.to_string
      (Permission_run.preset context.permission))
  :: "accesses:" :: access_lines
  @ match change_lines with [] -> [] | lines -> "change:" :: lines

let explanation_json context explanation =
  let kind, rule =
    match explanation with
    | Policy.Needs_review -> ("needs_review", None)
    | Policy.Needs_review_by_rule rule -> ("needs_review_by_rule", Some rule)
    | Policy.Denied_by_rule rule -> ("denied_by_rule", Some rule)
    | Policy.Allowed_by_rule rule -> ("allowed_by_rule", Some rule)
    | Policy.Allowed_by_grant -> ("allowed_by_grant", None)
  in
  json_obj
    (("kind", Jsont.Json.string kind)
    ::
    (match rule with
    | None -> []
    | Some rule -> (
        match rule_row context rule with
        | Some row ->
            [
              ("rule_id", Jsont.Json.string row.Permission_run.id);
              ( "rule_source",
                Jsont.Json.string (source_kind_string row.Permission_run.source)
              );
            ]
        | None -> [ ("rule_source", Jsont.Json.string "workflow") ])))

let change_json change =
  let module Change = Spice_permission.Request.Change in
  json_obj
    (List.filter_map Fun.id
       [
         Option.map
           (fun diff -> ("diff", Jsont.Json.string diff))
           (Change.diff change);
         Option.map
           (fun additions -> ("additions", Jsont.Json.int additions))
           (Change.additions change);
         Option.map
           (fun removals -> ("removals", Jsont.Json.int removals))
           (Change.removals change);
       ])

let reviewed_json context request =
  Jsont.Json.list
    (List.map
       (fun { access; explanation; change } ->
         json_obj
           ([
              ("access", json_encode Spice_permission.Access.jsont access);
              ("explanation", explanation_json context explanation);
            ]
           @
           match change with
           | None -> []
           | Some change -> [ ("change", change_json change) ]))
       (reviewed context request))

let permission_json_fields context request =
  [
    ( "mode",
      Jsont.Json.string
        (Spice_host.Permission.Preset.to_string
           (Permission_run.preset context.permission)) );
    ("reviewed", reviewed_json context request);
  ]

let json ~permission block =
  let call = Session.Waiting.call block in
  let turn = Some (Session.Waiting.turn block) in
  let shared =
    [
      ( "turn",
        match turn with
        | None -> json_null
        | Some turn -> Jsont.Json.string (Session.Turn.Id.to_string turn) );
      ("tool_call_id", Jsont.Json.string (Tool_call.id call));
      ("tool", Jsont.Json.string (Tool_call.name call));
    ]
  in
  match block with
  | Session.Waiting.Permission request ->
      json_obj
        (("kind", Jsont.Json.string "permission")
         :: ( "permission_id",
              Jsont.Json.string
                (Session.Permission.Id.to_string
                   (Session.Permission.Requested.id request)) )
         :: shared
        @ permission_json_fields permission request)
  | Session.Waiting.Host_tool _ ->
      let question =
        match question_text call with
        | None -> []
        | Some question -> [ ("question", Jsont.Json.string question) ]
      in
      json_obj ((("kind", Jsont.Json.string "host_tool") :: shared) @ question)
  | Session.Waiting.Tool_claim execution ->
      json_obj
        (("kind", Jsont.Json.string "tool_claim")
        :: ( "claim_id",
             Jsont.Json.string
               (Session.Tool_claim.Id.to_string
                  (Session.Tool_claim.Started.id execution)) )
        :: shared)

(* Hinted commands must survive copy-paste even for dash-prefixed values:
   cmdliner reads a dash-prefixed token as an option, so positional targets
   get the explicit [--] separator and option values use the [--flag=value]
   spelling. *)
let dash_prefixed value = String.length value > 0 && value.[0] = '-'

let positional_arg value =
  let quoted = shell_arg value in
  if dash_prefixed value then "-- " ^ quoted else quoted

let opt_arg flag value =
  let quoted = shell_arg value in
  if dash_prefixed value then flag ^ "=" ^ quoted else flag ^ " " ^ quoted

let commands ~session block =
  let reply =
    "spice run reply " ^ positional_arg (Session.Id.to_string session)
  in
  let call = Session.Waiting.call block in
  match block with
  | Session.Waiting.Permission request ->
      let permission =
        Session.Permission.Id.to_string
          (Session.Permission.Requested.id request)
      in
      [
        "allow once: " ^ reply ^ " " ^ opt_arg "--allow" permission;
        "allow session: " ^ reply ^ " " ^ opt_arg "--allow-session" permission;
        "deny: " ^ reply ^ " " ^ opt_arg "--deny" permission;
        "deny with message: " ^ reply ^ " "
        ^ opt_arg "--deny" permission
        ^ " --message TEXT|-";
      ]
  | Session.Waiting.Host_tool _ ->
      if Option.is_some (question_text call) then
        [
          "answer: " ^ reply ^ " "
          ^ opt_arg "--question" (Tool_call.id call)
          ^ " --answer TEXT";
        ]
      else if Option.is_some (plan_proposal call) then
        [
          "approve: " ^ reply ^ " --approve-plan";
          "reject: " ^ reply ^ " --reject-plan --message TEXT|-";
        ]
      else []
  | Session.Waiting.Tool_claim execution ->
      [
        "recover: " ^ reply ^ " "
        ^ opt_arg "--tool-interrupted"
            (Session.Tool_claim.Id.to_string
               (Session.Tool_claim.Started.id execution));
      ]

let resume_invocation ~session =
  "spice resume " ^ positional_arg (Session.Id.to_string session)

let resume_command ~session = "resume: " ^ resume_invocation ~session

let outcome_string = function
  | Session.Turn.Outcome.Completed -> "completed"
  | Session.Turn.Outcome.Step_limit -> "step_limit"
  | Session.Turn.Outcome.Interrupted _ -> "interrupted"
  | Session.Turn.Outcome.Failed _ -> "failed"
