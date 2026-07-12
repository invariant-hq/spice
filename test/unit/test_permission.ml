(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
open Spice_permission
module Json = Jsont.Json
module Workspace = Spice_workspace

let expect_invalid_message msg expected f =
  match f () with
  | _ -> failf "%s: expected Invalid_argument" msg
  | exception Invalid_argument actual -> equal string ~msg expected actual

let expect_decode_error msg codec json =
  match Json.decode codec json with
  | Ok _ -> failf "%s: expected decode error" msg
  | Error _ -> ()

let access_value = testable ~pp:Access.pp ~equal:Access.equal ()
let request_value = testable ~pp:Request.pp ~equal:Request.equal ()
let item_value = testable ~pp:Request.Item.pp ~equal:Request.Item.equal ()
let rule_value = testable ~pp:Policy.Rule.pp ~equal:Policy.Rule.equal ()
let policy_value = testable ~pp:Policy.pp ~equal:Policy.equal ()

let roundtrip msg testable codec value =
  equal testable ~msg value (decode codec (encode codec value))

let local path =
  let parsed =
    if String.equal path "" then Ok Spice_path.Rel.root
    else Spice_path.Rel.of_string path
  in
  match parsed with
  | Ok path -> path
  | Error error ->
      failf "invalid local path: %s" (Spice_path.Error.message error)

let abs path =
  match Spice_path.Abs.of_string path with
  | Ok path -> path
  | Error error ->
      failf "invalid absolute path: %s" (Spice_path.Error.message error)

let workspace_root_key key =
  match Workspace.Root.Key.of_string key with
  | Ok key -> key
  | Error error ->
      failf "invalid workspace root key: %s" (Workspace.Root.Key.message error)

let workspace_path ?root_key ?(root = "/repo") relative =
  let root =
    match root_key with
    | None -> Workspace.Root.make (abs root)
    | Some key -> Workspace.Root.make ~key:(workspace_root_key key) (abs root)
  in
  Workspace.Path.make ~root (local relative)

let workspace_scope_key ?(root_key = "/repo") relative =
  Access.Path_scope.workspace_key
    ~root_key:(workspace_root_key root_key)
    ~relative:(local relative)

let workspace_read relative = Access.path ~op:`Read (workspace_path relative)

let workspace_modify relative =
  Access.path ~op:`Modify (workspace_path relative)

let outside_path op path = Access.outside_workspace_path ~op (abs path)
let unknown_read path = Access.unknown_path ~op:`Read path
let unknown_path op path = Access.unknown_path ~op path
let default_cwd = Access.Path_scope.workspace (workspace_path "")

let enforced ?(read = Access.Command.Confinement.Project)
    ?(write = Access.Command.Confinement.Read_only)
    ?(network = Access.Command.Confinement.Restricted) () =
  Access.Command.Enforced Access.Command.Confinement.{ read; write; network }

let default_cwd_match =
  Policy.Match.Path.exact_key ~root_key:(workspace_root_key "/repo")
    ~relative:(local "")

let shell ?(cwd = default_cwd) ?(execution = Access.Command.Direct) command =
  Access.command (Access.Command.shell ~cwd ~execution command)

let argv ?(cwd = default_cwd) ?(execution = Access.Command.Direct) ~program args =
  Access.command (Access.Command.argv ~cwd ~execution ~program args)

let exec program args = argv ~program args

let code ?(cwd = default_cwd) ?(execution = Access.Command.Direct) ~language
    source =
  Access.code ~cwd ~execution ~language source

let enforced_exec program args =
  Access.argv ~cwd:default_cwd ~execution:(enforced ()) ~program args

let argv_prefix ?(execution = Access.Command.Direct)
    ?(cwd = default_cwd_match) ~program ~args () =
  Policy.Match.command
    (Policy.Match.Command.argv_prefix ~execution ~cwd ~program ~args ())

let argv_exact ?(cwd = default_cwd) ?(execution = Access.Command.Direct)
    ~program ~args () =
  Policy.Match.command
    (Policy.Match.Command.exact
       (Access.Command.argv ~cwd ~execution ~program args))

let extension name = Access.custom name
let request access = Request.of_accesses [ access ]

let restore_review request accesses =
  let reasons =
    List.map (fun access -> (access, Policy.Review.Unmatched)) accesses
  in
  match Policy.Review.restore request reasons with
  | Ok review -> review
  | Error Policy.Review.Empty_accesses ->
      failf "review restore unexpectedly empty"
  | Error (Policy.Review.Access_not_in_request access) ->
      failf "review restore rejected access: %a" Access.pp access

let remember_exact = Policy.Review.remember

let expect_allow msg = function
  | Policy.Decision.Allowed -> ()
  | Policy.Decision.Review _ -> failf "%s: expected allow, got review" msg
  | Policy.Decision.Denied _ -> failf "%s: expected allow, got deny" msg

let expect_review msg = function
  | Policy.Decision.Review review -> review
  | Policy.Decision.Allowed -> failf "%s: expected review, got allow" msg
  | Policy.Decision.Denied _ -> failf "%s: expected review, got deny" msg

let expect_deny msg = function
  | Policy.Decision.Denied _ -> ()
  | Policy.Decision.Allowed -> failf "%s: expected deny, got allow" msg
  | Policy.Decision.Review _ -> failf "%s: expected deny, got review" msg

let expect_denial msg = function
  | Policy.Decision.Denied (denial, _) -> denial
  | Policy.Decision.Allowed -> failf "%s: expected deny, got allow" msg
  | Policy.Decision.Review _ -> failf "%s: expected deny, got review" msg

let expect_denials msg = function
  | Policy.Decision.Denied (denial, denials) -> denial :: denials
  | Policy.Decision.Allowed -> failf "%s: expected deny, got allow" msg
  | Policy.Decision.Review _ -> failf "%s: expected deny, got review" msg

let access_constructor_validation () =
  ignore (Access.path ~op:`Read (workspace_path ~root:"/r" ""));
  expect_invalid_arg "unknown path cannot be empty" (fun () ->
      ignore (Access.unknown_path ~op:`Read ""));
  expect_invalid_arg "shell command cannot be empty" (fun () ->
      ignore (shell ""));
  expect_invalid_arg "exec program cannot be empty" (fun () ->
      ignore (argv ~program:"" []));
  ignore (argv ~program:"printf" [ "" ]);
  expect_invalid_arg "code language cannot be empty" (fun () ->
      ignore (code ~language:"" "1 + 1"));
  expect_invalid_arg "code source cannot be empty" (fun () ->
      ignore (code ~language:"ocaml" ""));
  expect_invalid_arg "unknown cwd cannot be empty" (fun () ->
      ignore (Access.Path_scope.unknown ""));
  (match Workspace.Root.Key.of_string "" with
  | Error Workspace.Root.Key.Empty -> ()
  | Ok _ -> failf "empty workspace root key should be rejected");
  expect_invalid_arg "network host cannot be empty" (fun () ->
      ignore (Access.network ~protocol:`Https ~host:"" ()));
  expect_invalid_arg "custom protocol cannot be empty" (fun () ->
      ignore (Access.network ~protocol:(`Other "") ~host:"socket" ()));
  expect_invalid_arg "network port must be in range" (fun () ->
      ignore (Access.network ~protocol:`Https ~port:0 ~host:"example.com" ()));
  expect_invalid_arg "extension name cannot be empty" (fun () ->
      ignore (Access.custom ""));
  expect_invalid_arg "extension subject cannot be empty" (fun () ->
      ignore (Access.custom ~subject:"" "capability"))

let validation_errors_name_the_function_and_constraint () =
  expect_invalid_message "shell command error is actionable"
    "Spice_permission.Access.Command.shell: text must not be empty" (fun () ->
      ignore (shell ""));
  expect_invalid_message "request access error is actionable"
    "Spice_permission.Request.of_accesses: accesses must not be empty"
    (fun () -> ignore (Request.of_accesses []))

let shell_and_exec_have_distinct_keys () =
  let shell = shell "git status" in
  let exec = argv ~program:"git" [ "status" ] in
  check "shell is command class" (Access.kind shell = `Command);
  check "exec is command class" (Access.kind exec = `Command);
  not_equal access_value ~msg:"shell and exec do not match exactly" shell exec

let code_identity_includes_source_language_cwd_and_route () =
  let ocaml = code ~language:"ocaml" "1 + 1" in
  let other_source = code ~language:"ocaml" "2 + 2" in
  let other_language = code ~language:"reason" "1 + 1" in
  let other_cwd =
    code
      ~cwd:(Access.Path_scope.workspace (workspace_path "lib"))
      ~language:"ocaml" "1 + 1"
  in
  let other_route =
    code ~execution:(enforced ()) ~language:"ocaml" "1 + 1"
  in
  check "code is command class" (Access.kind ocaml = `Command);
  List.iter
    (fun distinct ->
      not_equal access_value ~msg:"code identity preserves every execution fact"
        ocaml distinct)
    [ other_source; other_language; other_cwd; other_route ]

let workspace_access_is_stable_identity () =
  let first = Access.path_scope ~op:`Modify (workspace_scope_key "lib/a.ml") in
  let second = Access.path_scope ~op:`Modify (workspace_scope_key "lib/a.ml") in
  equal access_value ~msg:"same workspace identity is structurally equal" first
    second;
  equal int ~msg:"comparison uses access identity" 0
    (Access.compare first second);
  let other_root =
    Access.path_scope ~op:`Modify
      (workspace_scope_key ~root_key:"/other" "lib/a.ml")
  in
  not_equal access_value ~msg:"workspace root key affects exact matching" first
    other_root

let workspace_root_key_is_used_by_live_paths () =
  let access =
    Access.path ~op:`Modify
      (workspace_path ~root:"/tmp/checkout" ~root_key:"repo-stable" "lib/a.ml")
  in
  let same_key =
    Access.path_scope ~op:`Modify
      (workspace_scope_key ~root_key:"repo-stable" "lib/a.ml")
  in
  let path_rule =
    Policy.Match.path
      (Policy.Match.Path.under
         (workspace_path ~root:"/tmp/checkout" ~root_key:"repo-stable" "lib"))
  in
  equal access_value ~msg:"live path access uses Root.key" same_key access;
  expect_allow "path-under uses Root.key"
    (Policy.decide
       (Policy.make [ Policy.Rule.allow path_rule ])
       (request access))

let request_constructor_validation () =
  expect_invalid_arg "requests need at least one access" (fun () ->
      ignore (Request.of_accesses []));
  expect_invalid_arg "request source cannot be empty" (fun () ->
      ignore (Request.of_accesses ~source:"" [ extension "confirm" ]));
  let duplicate = workspace_read "README.md" in
  let same_key =
    Access.path_scope ~op:`Read (workspace_scope_key "README.md")
  in
  let r = Request.of_accesses ~source:"tool" [ extension "confirm" ] in
  equal (option string) ~msg:"request source is retained" (Some "tool")
    (Request.source r);
  equal (list access_value) ~msg:"request accesses are retained"
    [ extension "confirm" ]
    (Request.accesses r);
  let with_duplicates =
    Request.of_accesses [ duplicate; same_key; duplicate ]
  in
  equal (list access_value) ~msg:"normalized accesses remove exact duplicates"
    [ duplicate ]
    (Request.normalized_accesses with_duplicates);
  equal int ~msg:"unique accesses collapse duplicate identities" 1
    (Access.Set.cardinal (Request.unique_accesses with_duplicates))

let default_policy_reviews_everything () =
  let read = workspace_read "README.md" in
  let review =
    expect_review "review-all policy asks about reads"
      (Policy.decide Policy.default (request read))
  in
  equal (list access_value) ~msg:"review contains the unmatched access" [ read ]
    (Policy.Review.accesses review);
  let command = shell "make" in
  let review =
    expect_review "review-all policy asks about commands"
      (Policy.decide Policy.default (request command))
  in
  equal (list access_value) ~msg:"command review contains the unmatched access"
    [ command ]
    (Policy.Review.accesses review)

let all_access_rules_are_explicit () =
  let command = shell "make test" in
  expect_allow "dangerous allow-all rule allows commands"
    (Policy.decide
       (Policy.make [ Policy.Rule.allow_all_dangerously ])
       (request command));
  expect_deny "deny-all rule denies commands"
    (Policy.decide (Policy.make [ Policy.Rule.deny_all ]) (request command));
  let review =
    expect_review "review-all policy reviews unmatched commands"
      (Policy.decide Policy.default (request command))
  in
  let grants = remember_exact review Policy.Grants.empty in
  expect_allow "review-all policy still respects grants"
    (Policy.decide ~grants Policy.default (request command));
  ignore
    (expect_review "review-all rule overrides grants"
       (Policy.decide ~grants
          (Policy.make [ Policy.Rule.always_review ])
          (request command)))

let class_read_rule_allows_reads () =
  let policy = Policy.make [ Policy.Rule.allow (Policy.Match.kind `Read) ] in
  expect_allow "read class rule allows path reads"
    (Policy.decide policy (request (unknown_read "README.md")));
  ignore
    (expect_review "read class rule does not allow edits"
       (Policy.decide policy (request (workspace_modify "lib/a.ml"))))

let command_deny_rule_denies_shell_and_exec () =
  let policy = Policy.make [ Policy.Rule.deny (Policy.Match.kind `Command) ] in
  expect_deny "command class deny rejects shell"
    (Policy.decide policy (request (shell "make")));
  expect_deny "command class deny rejects exec"
    (Policy.decide policy (request (exec "make" [])))

let first_matching_rule_wins () =
  let command = request (shell "make") in
  let deny_first =
    Policy.make
      [
        Policy.Rule.deny (Policy.Match.kind `Command);
        Policy.Rule.allow (Policy.Match.kind `Command);
      ]
  in
  expect_deny "earlier deny is not overridden by later allow"
    (Policy.decide deny_first command);
  let allow_first =
    Policy.make
      [
        Policy.Rule.allow (Policy.Match.kind `Command);
        Policy.Rule.deny (Policy.Match.kind `Command);
      ]
  in
  expect_allow "earlier allow is not overridden by later deny"
    (Policy.decide allow_first command)

let grouped_request_semantics () =
  let read = workspace_read "README.md" in
  let edit = workspace_modify "lib/a.ml" in
  let command = shell "make" in
  let policy =
    Policy.make
      [
        Policy.Rule.allow (Policy.Match.kind `Read);
        Policy.Rule.deny (Policy.Match.kind `Command);
      ]
  in
  expect_deny "deny wins over review in grouped requests"
    (Policy.decide policy (Request.of_accesses [ read; edit; command ]));
  let review =
    expect_review "review contains only accesses needing review"
      (Policy.decide policy (Request.of_accesses [ read; edit ]))
  in
  equal (list access_value) ~msg:"only the edit needs review" [ edit ]
    (Policy.Review.accesses review);
  let review =
    expect_review "review deduplicates exact duplicate accesses"
      (Policy.decide policy (Request.of_accesses [ read; edit; edit ]))
  in
  equal (list access_value) ~msg:"duplicate edit appears once" [ edit ]
    (Policy.Review.accesses review);
  let allow_all =
    Policy.make
      [
        Policy.Rule.allow (Policy.Match.kind `Read);
        Policy.Rule.allow (Policy.Match.kind `Write);
      ]
  in
  expect_allow "grouped request allows only when every access is allowed"
    (Policy.decide allow_all (Request.of_accesses [ read; edit ]));
  ignore
    (expect_review "one unallowed access makes the group need review"
       (Policy.decide
          (Policy.make [ Policy.Rule.allow (Policy.Match.kind `Read) ])
          (Request.of_accesses [ read; edit ])))

let rule_matchers_cover_common_policy_patterns () =
  expect_decode_error "path under JSON root key cannot be empty"
    Policy.Rule.jsont
    (json_object
       [
         ("action", Json.string "allow");
         ( "matcher",
           json_object
             [
               ("type", Json.string "path-under");
               ("root_key", Json.string "");
               ("relative", Json.string "lib");
             ] );
       ]);
  expect_invalid_arg "exec prefix program cannot be empty" (fun () ->
      ignore (argv_prefix ~program:"" ~args:[] ()));
  ignore (argv_prefix ~program:"printf" ~args:[ "" ] ());
  expect_invalid_arg "exec exact program cannot be empty" (fun () ->
      ignore (argv_exact ~program:"" ~args:[] ()));
  (match Workspace.Root.Key.of_string "" with
  | Error Workspace.Root.Key.Empty -> ()
  | Ok _ -> failf "empty cwd root key should be rejected");
  expect_invalid_arg "network host cannot be empty" (fun () ->
      ignore (Policy.Match.network_host ~host:"" ()));
  expect_invalid_arg "extension subject cannot be empty" (fun () ->
      ignore (Policy.Match.custom ~subject:"" "tool"));
  let path_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Modify
             (Policy.Match.Path.under (workspace_path "lib")));
      ]
  in
  expect_allow "path under allows descendants"
    (Policy.decide path_policy (request (workspace_modify "lib/a.ml")));
  let path_key_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Modify
             (Policy.Match.Path.under_key
                ~root_key:(workspace_root_key "/repo")
                ~relative:(local "lib")));
      ]
  in
  expect_allow "path under key allows descendants"
    (Policy.decide path_key_policy (request (workspace_modify "lib/a.ml")));
  let path_scope_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Modify
             (Policy.Match.Path.exact (workspace_path "lib/a.ml")));
      ]
  in
  expect_allow "path scope exact allows matching path"
    (Policy.decide path_scope_policy (request (workspace_modify "lib/a.ml")));
  ignore
    (expect_review "path scope exact rejects descendants"
       (Policy.decide path_scope_policy
          (request (workspace_modify "lib/a.ml/generated"))));
  let workspace_path_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Read Policy.Match.Path.workspace);
      ]
  in
  expect_allow "workspace path matcher allows classified workspace paths"
    (Policy.decide workspace_path_policy (request (workspace_read "README.md")));
  ignore
    (expect_review "workspace path matcher checks op"
       (Policy.decide workspace_path_policy
          (request (workspace_modify "README.md"))));
  ignore
    (expect_review "workspace path matcher rejects outside paths"
       (Policy.decide workspace_path_policy
          (request (outside_path `Read "/repo/README.md"))));
  ignore
    (expect_review "workspace path matcher rejects unknown paths"
       (Policy.decide workspace_path_policy
          (request (unknown_read "README.md"))));
  ignore
    (expect_review "path under is segment based"
       (Policy.decide path_policy (request (workspace_modify "liberty/a.ml"))));
  ignore
    (expect_review "path under does not match outside-workspace paths"
       (Policy.decide path_policy
          (request (outside_path `Modify "/repo/lib/a.ml"))));
  ignore
    (expect_review "path under does not match unknown paths"
       (Policy.decide path_policy
          (request (unknown_path `Modify "/repo/lib/a.ml"))));
  let outside_policy =
    Policy.make
      [
        Policy.Rule.deny
          (Policy.Match.path ~op:`Modify Policy.Match.Path.outside_workspace);
      ]
  in
  expect_deny "outside-workspace matcher denies matching paths"
    (Policy.decide outside_policy
       (request (outside_path `Modify "/tmp/outside.ml")));
  ignore
    (expect_review "outside-workspace matcher checks op"
       (Policy.decide outside_policy
          (request (outside_path `Read "/tmp/outside.ml"))));
  ignore
    (expect_review "outside-workspace matcher does not match workspace paths"
       (Policy.decide outside_policy (request (workspace_modify "lib/a.ml"))));
  let unknown_policy =
    Policy.make
      [
        Policy.Rule.review (Policy.Match.path Policy.Match.Path.unknown);
        Policy.Rule.allow_all_dangerously;
      ]
  in
  ignore
    (expect_review "unknown path matcher matches unknown paths"
       (Policy.decide unknown_policy (request (unknown_path `Delete "target"))));
  expect_allow "unknown path matcher does not match workspace paths"
    (Policy.decide unknown_policy (request (workspace_read "README.md")));
  let exec_policy =
    Policy.make
      [ Policy.Rule.allow (argv_prefix ~program:"git" ~args:[ "status" ] ()) ]
  in
  expect_allow "exec prefix allows matching argv prefix"
    (Policy.decide exec_policy (request (exec "git" [ "status"; "--short" ])));
  ignore
    (expect_review "exec prefix does not match shell text"
       (Policy.decide exec_policy (request (shell "git status --short"))));
  let command_exact_policy =
    Policy.make
      [
        Policy.Rule.allow
          (argv_exact ~program:"git" ~args:[ "status"; "--short" ] ());
      ]
  in
  expect_allow "exec exact allows matching argv"
    (Policy.decide command_exact_policy
       (request (exec "git" [ "status"; "--short" ])));
  ignore
    (expect_review "exec exact rejects extra argv"
       (Policy.decide command_exact_policy
          (request (exec "git" [ "status"; "--short"; "--branch" ]))));
  let cwd_policy =
    Policy.make
      [
        Policy.Rule.allow
          (argv_prefix
             ~cwd:
               (Policy.Match.Path.under_key
                  ~root_key:(workspace_root_key "/repo")
                  ~relative:(local "."))
             ~program:"dune" ~args:[ "build" ] ());
      ]
  in
  expect_allow "exec prefix can require cwd under workspace root"
    (Policy.decide cwd_policy
       (request
          (argv
             ~cwd:(Access.Path_scope.workspace (workspace_path "src"))
             ~program:"dune" [ "build"; "@all" ])));
  let workspace_cwd_policy =
    Policy.make
      [
        Policy.Rule.allow
          (argv_prefix ~cwd:Policy.Match.Path.workspace ~program:"dune"
             ~args:[ "build" ] ());
      ]
  in
  expect_allow "exec prefix can require any workspace cwd"
    (Policy.decide workspace_cwd_policy
       (request
          (argv
             ~cwd:(Access.Path_scope.workspace (workspace_path "tests"))
             ~program:"dune" [ "build"; "@all" ])));
  ignore
    (expect_review "workspace cwd matcher rejects outside cwd"
       (Policy.decide workspace_cwd_policy
          (request
             (argv
                ~cwd:(Access.Path_scope.outside_workspace (abs "/tmp/repo"))
                ~program:"dune" [ "build" ]))));
  ignore
    (expect_review "exec cwd matcher rejects another cwd"
       (Policy.decide cwd_policy
          (request
             (argv
                ~cwd:(Access.Path_scope.outside_workspace (abs "/tmp/repo"))
                ~program:"dune" [ "build" ]))));
  ignore
    (expect_review "exec cwd matcher rejects unknown cwd"
       (Policy.decide cwd_policy
          (request
             (argv ~cwd:(Access.Path_scope.unknown "unresolved")
                ~program:"dune" [ "build" ]))));
  let network_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.network_host ~protocol:`Https ~port:443
             ~host:"example.com" ());
      ]
  in
  expect_allow "network host allows matching endpoint"
    (Policy.decide network_policy
       (request
          (Access.network ~protocol:`Https ~port:443 ~host:"example.com" ())));
  ignore
    (expect_review "network host checks port when provided"
       (Policy.decide network_policy
          (request
             (Access.network ~protocol:`Https ~port:8443 ~host:"example.com" ()))));
  let extension_policy =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.custom ~subject:"todo" "todo_write");
      ]
  in
  expect_allow "extension matcher allows matching extension facts"
    (Policy.decide extension_policy
       (request (Access.custom ~subject:"todo" "todo_write")));
  ignore
    (expect_review "extension matcher checks subject when provided"
       (Policy.decide extension_policy
          (request (Access.custom ~subject:"note" "todo_write"))))

let grants_allow_reviewed_accesses () =
  let command = shell "make test" in
  let review =
    expect_review "review-all policy reviews shell command"
      (Policy.decide Policy.default (request command))
  in
  let grants = remember_exact review Policy.Grants.empty in
  is_true ~msg:"grants remember reviewed access"
    (Policy.Grants.allows grants command);
  expect_allow "granted access is allowed without another review"
    (Policy.decide ~grants Policy.default (request command))

let remember_adds_exact_reviewed_grants () =
  let command = shell "make test" in
  let review =
    expect_review "review-all policy reviews shell command"
      (Policy.decide Policy.default (request command))
  in
  let grants = Policy.Review.remember review Policy.Grants.empty in
  check "remember adds exact grants for reviewed accesses"
    (Policy.Grants.allows grants command)

let review_of_accesses_uses_durable_request_subset () =
  let read = workspace_read "README.md" in
  let command = shell "make test" in
  let request = Request.of_accesses ~source:"tool" [ read; command ] in
  let review = restore_review request [ command ] in
  equal (list access_value) ~msg:"durable access subset preserves request order"
    [ read; command ]
    (Policy.Review.accesses (restore_review request [ command; read ]));
  equal (list access_value) ~msg:"durable access subset is normalized"
    [ command ]
    (Policy.Review.accesses (restore_review request [ command; command ]));
  let grants = Policy.Review.remember review Policy.Grants.empty in
  check "remember grants only the durable subset"
    (Policy.Grants.allows grants command
    && not (Policy.Grants.allows grants read));
  (match Policy.Review.restore request [] with
  | Error Policy.Review.Empty_accesses -> ()
  | Ok _ | Error (Policy.Review.Access_not_in_request _) ->
      failf "durable access subset cannot be empty");
  match
    Policy.Review.restore request
      [ (workspace_modify "lib/a.ml", Policy.Review.Unmatched) ]
  with
  | Error (Policy.Review.Access_not_in_request _) -> ()
  | Ok _ | Error Policy.Review.Empty_accesses ->
      failf "durable access subset must belong to request"

let ask_of_access_set_uses_request_subset () =
  let read = workspace_read "README.md" in
  let command = shell "make test" in
  let request = Request.of_accesses ~source:"tool" [ read; command ] in
  let review = restore_review request [ command ] in
  equal (list access_value) ~msg:"access set preserves request access"
    [ command ]
    (Policy.Review.accesses review);
  (match Policy.Review.restore request [] with
  | Error Policy.Review.Empty_accesses -> ()
  | Ok _ | Error (Policy.Review.Access_not_in_request _) ->
      failf "access set subset cannot be empty");
  match
    Policy.Review.restore request
      [ (workspace_modify "lib/a.ml", Policy.Review.Unmatched) ]
  with
  | Error (Policy.Review.Access_not_in_request _) -> ()
  | Ok _ | Error Policy.Review.Empty_accesses ->
      failf "access set subset must belong to request"

let grants_are_exact_key_matches () =
  let cwd = Access.Path_scope.workspace (workspace_path "") in
  let other_cwd = Access.Path_scope.outside_workspace (abs "/tmp/repo") in
  let command = shell ~cwd "make test" in
  let other_cwd = shell ~cwd:other_cwd "make test" in
  let other_command = shell ~cwd "make build" in
  let review =
    expect_review "review-all policy reviews shell command"
      (Policy.decide Policy.default (request command))
  in
  let grants = remember_exact review Policy.Grants.empty in
  ignore
    (expect_review "grant does not allow same shell text in another cwd"
       (Policy.decide ~grants Policy.default (request other_cwd)));
  ignore
    (expect_review "grant does not allow another shell command"
       (Policy.decide ~grants Policy.default (request other_command)))

let rules_override_grants () =
  let command = shell "make test" in
  let review =
    expect_review "review-all policy reviews shell command"
      (Policy.decide Policy.default (request command))
  in
  let grants = remember_exact review Policy.Grants.empty in
  let deny_commands =
    Policy.make [ Policy.Rule.deny (Policy.Match.kind `Command) ]
  in
  expect_deny "deny rules override session grants"
    (Policy.decide ~grants deny_commands (request command));
  let review_commands =
    Policy.make [ Policy.Rule.review (Policy.Match.kind `Command) ]
  in
  ignore
    (expect_review "review rules override session grants"
       (Policy.decide ~grants review_commands (request command)))

let deny_decisions_are_inspectable () =
  let read = workspace_read "README.md" in
  let edit = workspace_modify "lib/a.ml" in
  let command = shell "make test" in
  let deny_command = Policy.Rule.deny (Policy.Match.kind `Command) in
  let deny_edit = Policy.Rule.deny (Policy.Match.kind `Write) in
  let policy = Policy.make [ deny_edit; deny_command ] in
  let request = Request.of_accesses [ read; edit; command ] in
  let denials =
    expect_denials "deny decisions include denied accesses"
      (Policy.decide policy request)
  in
  equal int ~msg:"all denied accesses are reported" 2 (List.length denials);
  let denial = List.hd denials in
  equal request_value ~msg:"denial retains the original request" request
    (Policy.Denial.request denial);
  equal access_value ~msg:"denial reports the first denied access" edit
    (Policy.Denial.access denial);
  equal rule_value ~msg:"denial reports the denying rule" deny_edit
    (Policy.Denial.rule denial);
  equal (list access_value) ~msg:"denials preserve normalized request order"
    [ edit; command ]
    (List.map Policy.Denial.access denials)

let policy_explain_reports_provenance () =
  let read = workspace_read "README.md" in
  let command = shell "make test" in
  let allow_read = Policy.Rule.allow (Policy.Match.kind `Read) in
  let review_commands = Policy.Rule.review (Policy.Match.kind `Command) in
  let deny_command = Policy.Rule.deny (Policy.Match.exact command) in
  let policy = Policy.make [ allow_read; review_commands ] in
  let check_rule msg expected = function
    | Policy.Allowed_by_rule rule
    | Policy.Needs_review_by_rule rule
    | Policy.Denied_by_rule rule ->
        equal rule_value ~msg expected rule
    | Policy.Allowed_by_grant | Policy.Needs_review ->
        failf "%s: expected rule provenance" msg
  in
  check_rule "allowed access reports allow rule" allow_read
    (Policy.explain policy read);
  check_rule "reviewed access reports review rule" review_commands
    (Policy.explain policy command);
  (match Policy.explain Policy.default command with
  | Policy.Needs_review -> ()
  | Policy.Allowed_by_rule _ | Policy.Allowed_by_grant
  | Policy.Needs_review_by_rule _ | Policy.Denied_by_rule _ ->
      failf "unmatched access should report default review");
  let review =
    expect_review "review-all policy reviews shell command"
      (Policy.decide Policy.default (request command))
  in
  let grants = remember_exact review Policy.Grants.empty in
  (match Policy.explain ~grants Policy.default command with
  | Policy.Allowed_by_grant -> ()
  | Policy.Allowed_by_rule _ | Policy.Needs_review
  | Policy.Needs_review_by_rule _ | Policy.Denied_by_rule _ ->
      failf "granted access should report grant provenance");
  let deny_policy = Policy.make [ deny_command ] in
  check_rule "deny rule overrides grants in explanations" deny_command
    (Policy.explain ~grants deny_policy command)

let reviews_capture_the_deciding_reason () =
  let command = shell "dune build" in
  let read = workspace_read "README.md" in
  let rule = Policy.Rule.review (Policy.Match.exact command) in
  let review =
    expect_review "mixed request is reviewed"
      (Policy.decide (Policy.make [ rule ])
         (Request.of_accesses [ command; read ]))
  in
  match Policy.Review.reasons review with
  | [ (reviewed_command, Policy.Review.By_rule reviewed_rule);
      (reviewed_read, Policy.Review.Unmatched) ] ->
      check "review-rule access is preserved"
        (Access.equal command reviewed_command);
      equal rule_value ~msg:"captured review rule is preserved" rule
        reviewed_rule;
      check "unmatched access is preserved" (Access.equal read reviewed_read)
  | reasons ->
      failf "unexpected captured review reasons: %d entries"
        (List.length reasons)

let json_roundtrips_core_values () =
  let accesses =
    [
      workspace_read "README.md";
      workspace_modify "lib/a.ml";
      shell
        ~cwd:(Access.Path_scope.workspace (workspace_path ""))
        "dune runtest";
      argv
        ~cwd:(Access.Path_scope.workspace (workspace_path ""))
        ~program:"dune" [ "runtest" ];
      Access.argv ~cwd:default_cwd ~execution:(enforced ())
        ~program:"dune"
        [ "build" ];
      code ~execution:(enforced ()) ~language:"ocaml" "1 + 1;;";
      Access.network ~protocol:`Https ~port:443 ~host:"example.com" ();
      Access.network ~protocol:(`Other "unix") ~host:"socket" ();
      Access.custom ~subject:"todo" "todo_write";
    ]
  in
  List.iter
    (roundtrip "access JSON roundtrip" access_value Access.jsont)
    accesses;
  roundtrip "request JSON roundtrip" request_value Request.jsont
    (Request.of_accesses ~source:"tool:shell" ~display:"dune runtest" accesses);
  let rule =
    Policy.Rule.allow
      (Policy.Match.exact
         (shell
            ~cwd:(Access.Path_scope.workspace (workspace_path ""))
            "dune runtest"))
  in
  roundtrip "rule JSON roundtrip" rule_value Policy.Rule.jsont rule;
  let policy =
    Policy.make
      [
        Policy.Rule.allow (Policy.Match.kind `Read);
        Policy.Rule.review (Policy.Match.kind `Command);
        Policy.Rule.deny (Policy.Match.exact (shell "rm -rf _build"));
        Policy.Rule.allow
          (Policy.Match.path ~op:`Read Policy.Match.Path.workspace);
        Policy.Rule.allow
          (Policy.Match.path (Policy.Match.Path.under (workspace_path "test")));
        Policy.Rule.deny (Policy.Match.path Policy.Match.Path.outside_workspace);
        Policy.Rule.review
          (Policy.Match.path ~op:`Read Policy.Match.Path.unknown);
        Policy.Rule.allow (argv_prefix ~program:"git" ~args:[ "status" ] ());
        Policy.Rule.allow (argv_exact ~program:"git" ~args:[ "status" ] ());
        Policy.Rule.allow
          (argv_prefix
             ~cwd:
               (Policy.Match.Path.exact_key
                  ~root_key:(workspace_root_key "/repo")
                  ~relative:(local "."))
             ~program:"dune" ~args:[ "build" ] ());
        Policy.Rule.deny (Policy.Match.network_host ~host:"example.com" ());
      ]
  in
  roundtrip "policy JSON roundtrip" policy_value Policy.jsont policy

let json_rejects_invalid_state () =
  let bad_request_version =
    json_object
      [
        ("version", Json.int 2);
        ("accesses", Json.list [ encode Access.jsont (extension "ask") ]);
      ]
  in
  expect_decode_error "unknown request versions are rejected" Request.jsont
    bad_request_version;
  let bad_shell =
    json_object
      [
        ("type", Json.string "command");
        ("kind", Json.string "shell");
        ("text", Json.string "");
        ("execution", Json.string "direct");
      ]
  in
  expect_decode_error "invalid decoded accesses are rejected" Access.jsont
    bad_shell;
  let flat_enforced =
    json_object
      [
        ("type", Json.string "command");
        ("kind", Json.string "shell");
        ("text", Json.string "dune build");
        ("execution", Json.string "enforced");
        ( "cwd",
          json_object
            [ ("scope", Json.string "unknown"); ("path", Json.string ".") ] );
      ]
  in
  expect_decode_error "flat enforced execution identities are rejected"
    Access.jsont flat_enforced;
  let bad_workspace_path =
    json_object
      [
        ("type", Json.string "path");
        ("op", Json.string "read");
        ("scope", Json.string "workspace");
        ("root_key", Json.string "/repo");
        ("relative", Json.string "../secret");
        ("display", Json.string "/secret");
      ]
  in
  expect_decode_error "workspace relatives cannot escape root" Access.jsont
    bad_workspace_path;
  let bad_empty_workspace_path =
    json_object
      [
        ("type", Json.string "path");
        ("op", Json.string "read");
        ("scope", Json.string "workspace");
        ("root_key", Json.string "/repo");
        ("relative", Json.string "");
        ("display", Json.string "/repo");
      ]
  in
  expect_decode_error "workspace relatives cannot be empty" Access.jsont
    bad_empty_workspace_path;
  let bad_path_under =
    json_object
      [
        ("action", Json.string "allow");
        ( "matcher",
          json_object
            [
              ("type", Json.string "path-under");
              ("root_key", Json.string "/repo");
              ("relative", Json.string "/lib");
            ] );
      ]
  in
  expect_decode_error "path-under relatives cannot be absolute"
    Policy.Rule.jsont bad_path_under;
  let bad_empty_path_under =
    json_object
      [
        ("action", Json.string "allow");
        ( "matcher",
          json_object
            [
              ("type", Json.string "path-under");
              ("root_key", Json.string "/repo");
              ("relative", Json.string "");
            ] );
      ]
  in
  expect_decode_error "path-under relatives cannot be empty" Policy.Rule.jsont
    bad_empty_path_under;
  let incomplete_argv_prefix =
    json_object
      [
        ("action", Json.string "allow");
        ( "matcher",
          json_object
            [
              ("type", Json.string "command");
              ( "pattern",
                json_object
                  [
                    ("type", Json.string "argv-prefix");
                    ("program", Json.string "dune");
                    ("args", Json.list [ Json.string "build" ]);
                  ] );
            ] );
      ]
  in
  expect_decode_error "argv prefixes require execution and cwd"
    Policy.Rule.jsont incomplete_argv_prefix;
  let legacy_custom_command =
    json_object
      [
        ("type", Json.string "custom");
        ("kind", Json.string "command");
        ("name", Json.string "ocaml.eval");
        ("subject", Json.string "1 + 1");
      ]
  in
  expect_decode_error "custom accesses cannot impersonate commands"
    Access.jsont legacy_custom_command;
  let legacy_custom_command_matcher =
    json_object
      [
        ("action", Json.string "allow");
        ( "matcher",
          json_object
            [
              ("type", Json.string "custom");
              ("kind", Json.string "command");
              ("name", Json.string "ocaml.eval");
            ] );
      ]
  in
  expect_decode_error "custom matchers cannot select command work"
    Policy.Rule.jsont legacy_custom_command_matcher;
  let bad_policy_version =
    json_object [ ("version", Json.int 2); ("rules", Json.list []) ]
  in
  expect_decode_error "unknown policy versions are rejected" Policy.jsont
    bad_policy_version

let access_json_normalizes_outside_workspace_paths () =
  let outside_key_json =
    json_object
      [
        ("type", Json.string "path");
        ("op", Json.string "read");
        ("scope", Json.string "outside");
        ("path", Json.string "/a/../b");
      ]
  in
  equal access_value ~msg:"outside path access JSON is normalized"
    (outside_path `Read "/b")
    (decode Access.jsont outside_key_json);
  let cwd_key_json =
    json_object
      [
        ("type", Json.string "command");
        ("kind", Json.string "shell");
        ("text", Json.string "make");
        ("execution", json_object [ ("kind", Json.string "direct") ]);
        ( "cwd",
          json_object
            [
              ("scope", Json.string "outside"); ("path", Json.string "/a/../b");
            ] );
      ]
  in
  equal access_value ~msg:"outside cwd access JSON is normalized"
    (shell ~cwd:(Access.Path_scope.outside_workspace (abs "/b")) "make")
    (decode Access.jsont cwd_key_json)

let relative_scopes_match_any_workspace_root () =
  let read_in root_key relative =
    Access.path ~op:`Read (workspace_path ~root_key relative)
  in
  let allow_under =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Read
             (Policy.Match.Path.under_relative (local "lib")));
      ]
  in
  expect_allow "relative under matches one root"
    (Policy.decide allow_under (request (read_in "alpha" "lib/a.ml")));
  expect_allow "relative under matches another root"
    (Policy.decide allow_under (request (read_in "beta" "lib/sub/b.ml")));
  let (_ : Policy.Review.t) =
    expect_review "relative under is segment based"
      (Policy.decide allow_under (request (read_in "alpha" "lib2/a.ml")))
  in
  let (_ : Policy.Review.t) =
    expect_review "relative under skips outside paths"
      (Policy.decide allow_under (request (outside_path `Read "/lib/a.ml")))
  in
  let (_ : Policy.Review.t) =
    expect_review "relative under skips unknown paths"
      (Policy.decide allow_under (request (unknown_read "lib/a.ml")))
  in
  let allow_exact =
    Policy.make
      [
        Policy.Rule.allow
          (Policy.Match.path ~op:`Modify
             (Policy.Match.Path.exact_relative (local "dune-project")));
      ]
  in
  expect_allow "relative exact matches any root"
    (Policy.decide allow_exact
       (request
          (Access.path ~op:`Modify
             (workspace_path ~root_key:"gamma" "dune-project"))));
  let (_ : Policy.Review.t) =
    expect_review "relative exact skips other relatives"
      (Policy.decide allow_exact
         (request
            (Access.path ~op:`Modify
               (workspace_path ~root_key:"gamma" "doc/dune-project"))))
  in
  let under_rule =
    Policy.Rule.allow
      (Policy.Match.path ~op:`Read
         (Policy.Match.Path.under_relative (local "lib")))
  in
  roundtrip "relative under rule JSON roundtrips" rule_value Policy.Rule.jsont
    under_rule;
  let exact_rule =
    Policy.Rule.deny
      (Policy.Match.path (Policy.Match.Path.exact_relative (local ".env")))
  in
  roundtrip "relative exact rule JSON roundtrips" rule_value Policy.Rule.jsont
    exact_rule;
  let exec_rule =
    Policy.Rule.allow
      (argv_prefix
         ~cwd:(Policy.Match.Path.under_relative (local ""))
         ~program:"dune" ~args:[ "build" ] ())
  in
  roundtrip "relative cwd scope JSON roundtrips" rule_value Policy.Rule.jsont
    exec_rule

let rule_stable_text_distinguishes_rules () =
  let read_path scope = Policy.Match.path ~op:`Read scope in
  let under_alpha =
    Policy.Match.Path.under_key
      ~root_key:(workspace_root_key "alpha")
      ~relative:(local "lib")
  in
  let under_beta =
    Policy.Match.Path.under_key
      ~root_key:(workspace_root_key "beta")
      ~relative:(local "lib")
  in
  not_equal string ~msg:"root keys distinguish stable text"
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path under_alpha)))
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path under_beta)));
  let relative = Policy.Match.Path.under_relative (local "lib") in
  equal string ~msg:"equal rules share stable text"
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path relative)))
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path relative)));
  not_equal string ~msg:"relative scopes carry no root key"
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path under_alpha)))
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path relative)));
  not_equal string ~msg:"action distinguishes stable text"
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path relative)))
    (Policy.Rule.stable_text (Policy.Rule.deny (read_path relative)));
  not_equal string ~msg:"class distinguishes stable text"
    (Policy.Rule.stable_text (Policy.Rule.allow (Policy.Match.kind `Read)))
    (Policy.Rule.stable_text (Policy.Rule.allow (Policy.Match.kind `Write)));
  not_equal string ~msg:"exec prefix and exec exact differ"
    (Policy.Rule.stable_text
       (Policy.Rule.allow (argv_prefix ~program:"dune" ~args:[ "build" ] ())))
    (Policy.Rule.stable_text
       (Policy.Rule.allow (argv_exact ~program:"dune" ~args:[ "build" ] ())));
  not_equal string ~msg:"path op distinguishes stable text"
    (Policy.Rule.stable_text (Policy.Rule.allow (read_path relative)))
    (Policy.Rule.stable_text
       (Policy.Rule.allow (Policy.Match.path ~op:`Modify relative)))

(* Persisted rule ids are a digest of [Policy.Rule.stable_text]. The formula
   and the "v1" domain prefix mirror [rule_id] in lib/host/permission.ml; the
   expected 12-char ids are the ones committed in
   test/blackbox/test-cases/permission/rules.t. Pinning them here catches a
   change to [stable_text] (e.g. from the codec extraction) at the pure-library
   level, with a precise diff, before it silently invalidates every persisted
   permission rule the way a golden-only cram diff would. *)
let rule_id rule =
  Spice_digest.key ~length:12 ~domain:"spice.permission.rule.v1"
    [ Policy.Rule.stable_text rule ]

let rule_ids_are_stable_digests () =
  let deny_env =
    Policy.Rule.deny
      (Policy.Match.path (Policy.Match.Path.exact_relative (local ".env")))
  in
  let allow_workspace_read =
    Policy.Rule.allow (Policy.Match.path ~op:`Read Policy.Match.Path.workspace)
  in
  let allow_dune_build =
    Policy.Rule.allow
      (argv_prefix ~execution:(enforced ())
         ~cwd:Policy.Match.Path.workspace ~program:"dune" ~args:[ "build" ] ())
  in
  equal string ~msg:"deny .env rule id is stable" "b62807796201"
    (rule_id deny_env);
  equal string ~msg:"allow workspace read rule id is stable" "be7bf2b60ce9"
    (rule_id allow_workspace_read);
  equal string ~msg:"allow dune build rule id is stable" "b54551f76f68"
    (rule_id allow_dune_build)

let rule_observers_and_match_eliminator () =
  let matcher = Policy.Match.path ~op:`Read Policy.Match.Path.workspace in
  let rule = Policy.Rule.make Policy.Rule.Allow matcher in
  (match Policy.Rule.action rule with
  | Policy.Rule.Allow -> ()
  | Policy.Rule.Review | Policy.Rule.Deny ->
      failf "rule action observer returned the wrong action");
  equal rule_value ~msg:"Rule.make constructs the same rule as Rule.allow"
    (Policy.Rule.allow matcher)
    rule;
  check "matcher observer matches workspace reads"
    (Policy.Match.matches (Policy.Rule.matcher rule)
       (workspace_read "README.md"));
  check "matcher observer rejects workspace writes"
    (not
       (Policy.Match.matches (Policy.Rule.matcher rule)
          (workspace_modify "README.md")));
  check "direct matcher eliminator matches exact access"
    (Policy.Match.matches
       (Policy.Match.exact (shell "make test"))
       (shell "make test"))

let change_value = testable ~pp:Request.Change.pp ~equal:Request.Change.equal ()

let change_validation_and_lookup () =
  expect_invalid_message "change diff cannot be empty"
    "Spice_permission.Request.Change.make: diff must not be empty" (fun () ->
      Request.Change.make ~diff:"" ());
  expect_invalid_arg "change additions must be non-negative" (fun () ->
      ignore (Request.Change.make ~additions:(-1) ()));
  expect_invalid_arg "change removals must be non-negative" (fun () ->
      ignore (Request.Change.make ~removals:(-1) ()));
  expect_invalid_message "change needs at least one field"
    "Spice_permission.Request.Change.make: change must contain at least one \
     field" (fun () -> Request.Change.make ());
  let change = Request.Change.make ~diff:"+x" ~additions:1 ~removals:0 () in
  let later_change =
    Request.Change.make ~diff:"-y\n+z" ~additions:1 ~removals:1 ()
  in
  let target = workspace_modify "lib/a.ml" in
  let other = workspace_read "README.md" in
  let same_key_display =
    Access.path_scope ~op:`Modify (workspace_scope_key "lib/a.ml")
  in
  let target_item = Request.Item.make ~change target in
  let other_item = Request.Item.make other in
  let later_item = Request.Item.make ~change:later_change same_key_display in
  let r = Request.make [ target_item; other_item; later_item ] in
  equal (list item_value) ~msg:"items are found by stable access identity"
    [ target_item; later_item ]
    (Request.items_for_access r target);
  equal (list change_value) ~msg:"all changes are found by access identity"
    [ change; later_change ]
    (Request.changes_for_access r same_key_display);
  equal (list change_value) ~msg:"other accesses have no changes" []
    (Request.changes_for_access r other);
  let review = restore_review r [ target ] in
  equal (list access_value) ~msg:"review normalizes duplicate access identity"
    [ target ]
    (Policy.Review.accesses review);
  check "review access set contains the reviewed access"
    (Access.Set.equal
       (Access.Set.singleton target)
       (Policy.Review.access_set review));
  equal (list item_value) ~msg:"review items preserve duplicate occurrences"
    [ target_item; later_item ]
    (Policy.Review.items review);
  equal (list change_value) ~msg:"review changes preserve duplicate evidence"
    [ change; later_change ]
    (Policy.Review.changes review)

let change_is_inert_and_durable () =
  let target = workspace_modify "lib/a.ml" in
  let change = Request.Change.make ~diff:"-a\n+b" ~additions:1 ~removals:1 () in
  let bare = Request.of_accesses ~source:"edit_file" [ target ] in
  let with_change =
    Request.make ~source:"edit_file" [ Request.Item.make ~change target ]
  in
  not_equal request_value ~msg:"request equality includes change metadata" bare
    with_change;
  equal (list access_value) ~msg:"change does not change unique accesses"
    (Access.Set.elements (Request.unique_accesses bare))
    (Access.Set.elements (Request.unique_accesses with_change));
  let policy = Policy.make [ Policy.Rule.deny (Policy.Match.kind `Write) ] in
  let denied_bare =
    expect_denial "bare request denied" (Policy.decide policy bare)
  in
  let denied_change =
    expect_denial "change request denied" (Policy.decide policy with_change)
  in
  equal rule_value ~msg:"change does not change policy decisions"
    (Policy.Denial.rule denied_bare)
    (Policy.Denial.rule denied_change);
  roundtrip "request with change roundtrips" request_value Request.jsont
    with_change;
  roundtrip "request without change roundtrips" request_value Request.jsont bare

let high_impact_command_matcher () =
  let high_impact = Policy.Match.command Policy.Match.Command.high_impact in
  let matches access = Policy.Match.matches high_impact access in
  let yes msg access = check msg (matches access) in
  let no msg access = check msg (not (matches access)) in
  yes "rm -rf is high_impact" (exec "rm" [ "-rf"; "build" ]);
  yes "rm -r is high_impact" (exec "rm" [ "-r"; "dir" ]);
  no "rm -f of a named file is not high impact" (exec "rm" [ "-f"; "file" ]);
  yes "rm --recursive is high_impact" (exec "rm" [ "--recursive"; "dir" ]);
  no "rm of a named file is not flagged" (exec "rm" [ "notes.txt" ]);
  yes "an absolute rm path resolves by basename" (exec "/bin/rm" [ "-rf"; "x" ]);
  yes "git push --force is high_impact" (exec "git" [ "push"; "--force" ]);
  yes "git push -f is high_impact" (exec "git" [ "push"; "-f" ]);
  no "an ordinary git push is not flagged"
    (exec "git" [ "push"; "origin"; "main" ]);
  yes "git reset --hard is high_impact" (exec "git" [ "reset"; "--hard" ]);
  no "a plain git reset is not flagged" (exec "git" [ "reset" ]);
  yes "git clean --force is high_impact" (exec "git" [ "clean"; "-fd" ]);
  no "git status is not flagged" (exec "git" [ "status" ]);
  no "dd to an ordinary file is not high impact"
    (exec "dd" [ "if=/dev/zero"; "of=disk.img" ]);
  yes "dd directly to a device is high impact"
    (exec "dd" [ "if=image"; "of=/dev/disk2" ]);
  yes "an mkfs variant is high_impact" (exec "mkfs.ext4" [ "/dev/sdb1" ]);
  no "sudo is not high impact merely because it is privileged"
    (exec "sudo" [ "rm"; "x" ]);
  no "ls is not flagged" (exec "ls" [ "-la" ]);
  yes "a high_impact segment in shell text is flagged"
    (shell "cd build && rm -rf .");
  yes "a piped high_impact command is flagged" (shell "echo x | rm -rf y");
  yes "a wrapped high_impact command is flagged"
    (shell "find . -type f | xargs rm -rf");
  yes "command pass-through cannot hide destruction"
    (shell "command rm -rf build");
  yes "exec pass-through cannot hide destruction"
    (shell "exec rm -rf build");
  yes "shell -c argv is inspected recursively"
    (exec "bash" [ "-lc"; "rm -rf build" ]);
  yes "shell -c text is inspected recursively"
    (shell "sh -c 'git reset --hard'");
  yes "destruction hidden by a substitution is flagged"
    (shell "rm -rf $(cat targets)");
  no "an opaque command substitution is left to confinement"
    (shell "echo $(pick-command)");
  no "dynamic eval is left to confinement" (shell "eval \"$ACTION\"");
  no "a benign command with a redirect is not flagged"
    (shell "dune build 2> log.txt");
  no "a read-only shell command is not flagged" (shell "git status");
  no "opaque language source is not classified by shell heuristics"
    (code ~language:"ocaml" "Sys.remove \"important\"");
  no "the matcher ignores non-command accesses" (workspace_read "README.md");
  roundtrip "the high_impact rule roundtrips through json" rule_value
    Policy.Rule.jsont
    (Policy.Rule.review high_impact)

let enforced_command_matcher () =
  let matcher =
    Policy.Match.command
      (Policy.Match.Command.execution (enforced ()))
  in
  let direct = exec "dune" [ "build" ] in
  let enforced = enforced_exec "dune" [ "build" ] in
  check "direct route is explicit"
    (match direct with
    | Access.Command command ->
        Access.Command.execution command = Access.Command.Direct
    | Access.Path _ | Access.Network _ | Access.Custom _ -> false);
  check "enforced matcher rejects a direct route"
    (not (Policy.Match.matches matcher direct));
  check "enforced matcher accepts explicit sealed evidence"
    (Policy.Match.matches matcher enforced);
  not_equal access_value ~msg:"execution route is part of permission identity"
    direct enforced;
  roundtrip "enforced access roundtrips" access_value Access.jsont enforced;
  roundtrip "enforced matcher roundtrips" rule_value Policy.Rule.jsont
    (Policy.Rule.allow matcher)

let confinement_is_exact_command_and_grant_identity () =
  let project_read_only = enforced_exec "dune" [ "build" ] in
  let project_write =
    argv
      ~execution:(enforced ~write:Access.Command.Confinement.Workspace ())
      ~program:"dune" [ "build" ]
  in
  let read_all =
    argv ~execution:(enforced ~read:Access.Command.Confinement.All ())
      ~program:"dune" [ "build" ]
  in
  let network_enabled =
    argv ~execution:(enforced ~network:Access.Command.Confinement.Enabled ())
      ~program:"dune" [ "build" ]
  in
  List.iter
    (fun access ->
      not_equal access_value ~msg:"confinement changes command identity"
        project_read_only access;
      not_equal string ~msg:"confinement changes stable identity"
        (Access.stable_text project_read_only)
        (Access.stable_text access))
    [ project_write; read_all; network_enabled ];
  let review =
    expect_review "project command needs review under the pure default"
      (Policy.decide Policy.default (request project_read_only))
  in
  let grants = Policy.Review.remember review Policy.Grants.empty in
  check "exact grant remembers its confinement"
    (Policy.Grants.allows grants project_read_only);
  List.iter
    (fun access ->
      check "exact grant does not span confinement"
        (not (Policy.Grants.allows grants access)))
    [ project_write; read_all; network_enabled ]

let command_prefixes_preserve_execution_and_cwd () =
  let matcher =
    argv_prefix ~execution:(enforced ()) ~program:"dune"
      ~args:[ "build" ] ()
  in
  let other_cwd =
    Access.Path_scope.workspace
      (workspace_path ~root_key:"/other" ~root:"/other" "")
  in
  let matches = Policy.Match.matches matcher in
  check "prefix accepts its execution route and cwd"
    (matches (enforced_exec "dune" [ "build"; "@all" ]));
  check "prefix rejects direct execution"
    (not (matches (exec "dune" [ "build"; "@all" ])));
  check "prefix rejects externally confined execution"
    (not
       (matches
          (argv ~execution:Access.Command.External ~program:"dune"
             [ "build"; "@all" ])));
  check "prefix rejects another workspace"
    (not
       (matches
          (argv ~cwd:other_cwd ~execution:(enforced ())
             ~program:"dune" [ "build"; "@all" ])))

let () =
  run "spice.permission"
    [
      test "access constructors validate trusted claims"
        access_constructor_validation;
      test "validation errors name the function and constraint"
        validation_errors_name_the_function_and_constraint;
      test "shell and exec have distinct keys" shell_and_exec_have_distinct_keys;
      test "code identity includes source language cwd and route"
        code_identity_includes_source_language_cwd_and_route;
      test "workspace access is stable identity"
        workspace_access_is_stable_identity;
      test "workspace root key is used by live paths"
        workspace_root_key_is_used_by_live_paths;
      test "request constructors validate grouped facts"
        request_constructor_validation;
      test "default policy reviews everything" default_policy_reviews_everything;
      test "all-access rules are explicit" all_access_rules_are_explicit;
      test "read class rule allows reads" class_read_rule_allows_reads;
      test "command deny rule denies shell and exec"
        command_deny_rule_denies_shell_and_exec;
      test "first matching rule wins" first_matching_rule_wins;
      test "grouped request semantics" grouped_request_semantics;
      test "rule matchers cover common policy patterns"
        rule_matchers_cover_common_policy_patterns;
      test "grants allow reviewed accesses" grants_allow_reviewed_accesses;
      test "remember adds exact reviewed grants"
        remember_adds_exact_reviewed_grants;
      test "review of accesses uses durable request subset"
        review_of_accesses_uses_durable_request_subset;
      test "review restore uses request subset"
        ask_of_access_set_uses_request_subset;
      test "grants are exact key matches" grants_are_exact_key_matches;
      test "rules override grants" rules_override_grants;
      test "deny decisions are inspectable" deny_decisions_are_inspectable;
      test "policy explain reports provenance" policy_explain_reports_provenance;
      test "reviews capture the deciding reason"
        reviews_capture_the_deciding_reason;
      test "json roundtrips core values" json_roundtrips_core_values;
      test "json rejects invalid state" json_rejects_invalid_state;
      test "access json normalizes outside paths"
        access_json_normalizes_outside_workspace_paths;
      test "relative scopes match any workspace root"
        relative_scopes_match_any_workspace_root;
      test "rule stable text distinguishes rules"
        rule_stable_text_distinguishes_rules;
      test "rule ids are stable digests" rule_ids_are_stable_digests;
      test "rule observers and matcher eliminator"
        rule_observers_and_match_eliminator;
      test "change validation and lookup" change_validation_and_lookup;
      test "change is inert and durable" change_is_inert_and_durable;
      test "high_impact command matcher classifies irreversible commands"
        high_impact_command_matcher;
      test "enforced command matcher requires explicit execution evidence"
        enforced_command_matcher;
      test "confinement is exact command and grant identity"
        confinement_is_exact_command_and_grant_identity;
      test "command prefixes preserve execution route and cwd"
        command_prefixes_preserve_execution_and_cwd;
    ]
