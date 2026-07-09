(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Sandbox = Spice_sandbox
module Confinement = Spice_sandbox.Confinement
module Seatbelt = Spice_sandbox.Seatbelt
module Bubblewrap = Spice_sandbox.Bubblewrap
module Abs = Spice_path.Abs
module Digest = Spice_digest
module Json = Jsont.Json

let abs path = Abs.of_string_exn path
let argv program args = Sandbox.Argv.make ~program args
let argv_list argv = Sandbox.Argv.to_list argv
let profile_hash prepared = Digest.to_hex (Sandbox.Backend.profile prepared)

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let confinement_value = testable ~pp:Confinement.pp ~equal:Confinement.equal ()

let evidence_value =
  testable ~pp:Sandbox.Evidence.pp ~equal:Sandbox.Evidence.equal ()

let error_value = testable ~pp:Sandbox.Error.pp ~equal:Sandbox.Error.equal ()
let abs_value = testable ~pp:Abs.pp ~equal:Abs.equal ()

(* Confinement *)

let policy_normalizes () =
  let a =
    Confinement.read_only
    |> Confinement.writable [ abs "/work"; abs "/tmp" ]
    |> Confinement.writable [ abs "/work" ]
  in
  let b =
    Confinement.read_only |> Confinement.writable [ abs "/tmp"; abs "/work" ]
  in
  equal confinement_value ~msg:"writable roots dedup and order canonically" a b;
  equal (list abs_value) ~msg:"accessor reports canonical order"
    [ abs "/tmp"; abs "/work" ]
    (Confinement.writable_roots a)

let policy_protect_meta_validates () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> Confinement.protect_meta [ "a/b" ] Confinement.read_only);
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> Confinement.protect_meta [ ".." ] Confinement.read_only);
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () -> Confinement.protect_meta [ "" ] Confinement.read_only)

let policy_distinguishes_network () =
  let restricted = Confinement.read_only in
  let enabled =
    Confinement.read_only |> Confinement.network Confinement.Enabled
  in
  is_false ~msg:"network state participates in equality"
    (Confinement.equal restricted enabled);
  is_true ~msg:"read_only is restricted"
    (match Confinement.network_state restricted with
    | Confinement.Restricted -> true
    | Confinement.Enabled -> false)

let policy_write_carveouts_are_backend_independent () =
  let policy =
    Confinement.read_only
    |> Confinement.writable [ abs "/private/tmp"; abs "/private/tmp/ws" ]
    |> Confinement.protect_meta [ ".git" ]
    |> Confinement.protect
         [ abs "/outside/.spice"; abs "/private/tmp/ws/.spice" ]
  in
  equal (list abs_value) ~msg:"write carveouts are canonical and scoped"
    [
      abs "/private/tmp/.git";
      abs "/private/tmp/ws/.git";
      abs "/private/tmp/ws/.spice";
    ]
    (Confinement.write_carveouts policy)

(* Env *)

let env_partition_strips_credentials () =
  let backend =
    Sandbox.Backend.make ~id:"fake"
      ~available:(fun () -> Ok ())
      ~prepare:(fun _policy ->
        Ok (Sandbox.Backend.prepared ~prefix:[] ~profile:(Digest.string "env")))
      ()
  in
  let sandbox =
    Sandbox.seal ~backend
      (Sandbox.Spec.Confined
         (Confinement.read_only |> Confinement.writable [ abs "/work" ]))
  in
  let bindings =
    [
      ("PATH", "/usr/bin");
      ("ANTHROPIC_API_KEY", "sk-secret");
      ("GITHUB_TOKEN", "ghp_secret");
      ("openai_api_key", "lowercase-secret");
      ("SSH_AUTH_SOCK", "/tmp/agent.sock");
      ("GPG_AGENT_INFO", "/tmp/gpg.sock:123:1");
      ("DYLD_INSERT_LIBRARIES", "/tmp/evil.dylib");
      ("BASH_ENV", "/tmp/evil.sh");
      ("HOME", "/home/user");
      ("TMPDIR", "/tmp");
    ]
  in
  match
    Sandbox.spawn sandbox
      ~argv:(Sandbox.Argv.make ~program:"true" [])
      ~env:bindings
  with
  | Ok spawn ->
      equal
        (list (pair string string))
        ~msg:"benign bindings survive in order"
        [ ("PATH", "/usr/bin"); ("HOME", "/home/user"); ("TMPDIR", "/tmp") ]
        (Sandbox.Spawn.env spawn);
      let _kept, stripped = Sandbox.Env.partition bindings in
      equal (list string) ~msg:"stripped names only, in order"
        [
          "ANTHROPIC_API_KEY";
          "GITHUB_TOKEN";
          "openai_api_key";
          "SSH_AUTH_SOCK";
          "GPG_AGENT_INFO";
          "DYLD_INSERT_LIBRARIES";
          "BASH_ENV";
        ]
        stripped;
      List.iter
        (fun name ->
          is_false ~msg:"no stripped value leaks through names"
            (String.length name > 0 && String.contains name '-'))
        stripped
  | Error error -> fail (Sandbox.Error.message error)

(* Backend *)

let backend_none_refuses () =
  let backend = Sandbox.Backend.none ~reason:"unsupported here" in
  equal string ~msg:"refusing backend id" "none" (Sandbox.Backend.id backend);
  is_true ~msg:"refusing backend is unavailable"
    (Result.is_error (Sandbox.Backend.available backend));
  is_true ~msg:"refusing backend never prepares"
    (Result.is_error (Sandbox.Backend.prepare backend Confinement.read_only))

let policy_digest policy =
  Digest.string (Format.asprintf "%a" Confinement.pp policy)

let backend_validates () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () ->
      Sandbox.Backend.make ~id:""
        ~available:(fun () -> Ok ())
        ~prepare:(fun policy ->
          Ok
            (Sandbox.Backend.prepared ~prefix:[] ~profile:(policy_digest policy)))
        ())

let backend_prepared_validates_prefix_program () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () ->
      Sandbox.Backend.prepared ~prefix:[ ""; "--" ]
        ~profile:(Digest.string "bad-prefix"))

let backend_wraps_non_empty_argv () =
  let prepared =
    Sandbox.Backend.prepared ~prefix:[ "fake-wrap" ]
      ~profile:(Digest.string "wrap")
  in
  equal (list string) ~msg:"wrapper receives and returns non-empty argv"
    [ "fake-wrap"; "true"; "--version" ]
    (Sandbox.Backend.wrap prepared ~argv:(argv "true" [ "--version" ])
    |> Sandbox.Argv.to_list)

let backend_prefix_preserves_command () =
  let identity =
    Sandbox.Backend.prepared ~prefix:[] ~profile:(Digest.string "identity")
  in
  equal (list string) ~msg:"empty prefix leaves the command unchanged"
    [ "true"; "--version" ]
    (Sandbox.Backend.wrap identity ~argv:(argv "true" [ "--version" ])
    |> Sandbox.Argv.to_list);
  let multi =
    Sandbox.Backend.prepared ~prefix:[ "wrapper"; "-p"; "--" ]
      ~profile:(Digest.string "multi")
  in
  equal (list string)
    ~msg:
      "multi-token prefix prepends in order and preserves the command verbatim"
    [ "wrapper"; "-p"; "--"; "cmd"; "a"; "b" ]
    (Sandbox.Backend.wrap multi ~argv:(argv "cmd" [ "a"; "b" ])
    |> Sandbox.Argv.to_list)

let bubblewrap_backend_identity () =
  equal string ~msg:"bubblewrap backend id" "linux-bubblewrap"
    (Sandbox.Backend.id Bubblewrap.backend)

let bubblewrap_prepared policy =
  match Sandbox.Backend.prepare Bubblewrap.backend policy with
  | Ok prepared -> prepared
  | Error error -> fail (Sandbox.Error.message error)

let bubblewrap_wrap policy = function
  | [] -> invalid_arg "test bubblewrap argv must not be empty"
  | program :: args ->
      Sandbox.Backend.wrap
        (bubblewrap_prepared policy)
        ~argv:(argv program args)
      |> Sandbox.Argv.to_list

let bubblewrap_policy =
  Confinement.read_only
  |> Confinement.writable [ abs "/usr"; abs "/tmp" ]
  |> Confinement.protect_meta [ ".git"; ".spice" ]
  |> Confinement.protect [ abs "/usr/.spice/store" ]

let has_sequence sequence values =
  let rec starts_with sequence values =
    match (sequence, values) with
    | [], _ -> true
    | expected :: sequence, value :: values ->
        String.equal expected value && starts_with sequence values
    | _ :: _, [] -> false
  in
  let rec loop = function
    | [] -> starts_with sequence []
    | _ :: tail as values -> starts_with sequence values || loop tail
  in
  loop values

let bubblewrap_read_only_wrap_shape () =
  let argv =
    bubblewrap_wrap Confinement.read_only [ "/bin/sh"; "-c"; "true" ]
  in
  equal (list string) ~msg:"read-only bubblewrap argv"
    [
      "/usr/bin/bwrap";
      "--new-session";
      "--die-with-parent";
      "--unshare-user";
      "--unshare-pid";
      "--ro-bind";
      "/";
      "/";
      "--dev";
      "/dev";
      "--unshare-net";
      "--proc";
      "/proc";
      "--";
      "/bin/sh";
      "-c";
      "true";
    ]
    argv

let bubblewrap_workspace_write_wrap_shape () =
  let argv = bubblewrap_wrap bubblewrap_policy [ "true" ] in
  is_true ~msg:"workspace root is writable"
    (has_sequence [ "--bind"; "/usr"; "/usr" ] argv);
  is_true ~msg:"temp root is writable"
    (has_sequence [ "--bind"; "/tmp"; "/tmp" ] argv);
  is_true ~msg:"protected metadata is restored read-only"
    (has_sequence [ "--ro-bind-try"; "/usr/.git"; "/usr/.git" ] argv);
  is_true ~msg:"protected store path is restored read-only"
    (has_sequence
       [ "--ro-bind-try"; "/usr/.spice/store"; "/usr/.spice/store" ]
       argv)

let bubblewrap_skips_missing_writable_roots () =
  let missing = Filename.temp_file "spice-sandbox-missing-" "-root" in
  Sys.remove missing;
  let policy =
    Confinement.read_only |> Confinement.writable [ abs "/tmp"; abs missing ]
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_true ~msg:"existing root is bound"
    (has_sequence [ "--bind"; "/tmp"; "/tmp" ] argv);
  is_false ~msg:"missing root is not passed to bubblewrap"
    (has_sequence [ "--bind"; missing; missing ] argv)

let bubblewrap_nested_roots_share_carveouts () =
  let policy =
    Confinement.read_only
    |> Confinement.writable [ abs "/tmp"; abs "/tmp/ws" ]
    |> Confinement.protect_meta [ ".git" ]
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_true ~msg:"enclosing root carves out nested metadata"
    (has_sequence [ "--ro-bind-try"; "/tmp/ws/.git"; "/tmp/ws/.git" ] argv)

let bubblewrap_ignores_protected_paths_outside_writable_roots () =
  let policy =
    Confinement.read_only
    |> Confinement.writable [ abs "/tmp" ]
    |> Confinement.protect [ abs "/outside/.spice" ]
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_false ~msg:"outside protected path is not mounted"
    (has_sequence
       [ "--ro-bind-try"; "/outside/.spice"; "/outside/.spice" ]
       argv)

let bubblewrap_carveouts_follow_writable_binds () =
  let argv = bubblewrap_wrap bubblewrap_policy [ "true" ] in
  let rec index needle i = function
    | [] -> None
    | value :: rest ->
        if String.equal value needle then Some i else index needle (i + 1) rest
  in
  match (index "--bind" 0 argv, index "/usr/.git" 0 argv) with
  | Some bind, Some carveout ->
      is_true ~msg:"protected overlays come after writable binds"
        (bind < carveout)
  | Some _, None | None, Some _ | None, None ->
      fail "expected bind and carveout"

let bubblewrap_network_enabled_keeps_host_network () =
  let policy =
    Confinement.read_only |> Confinement.network Confinement.Enabled
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_false ~msg:"enabled network does not unshare net"
    (List.exists (String.equal "--unshare-net") argv)

let bubblewrap_hash_is_stable () =
  let hash_a = profile_hash (bubblewrap_prepared bubblewrap_policy) in
  let hash_b =
    profile_hash
      (bubblewrap_prepared
         (Confinement.read_only
         |> Confinement.protect [ abs "/usr/.spice/store" ]
         |> Confinement.protect_meta [ ".spice"; ".git" ]
         |> Confinement.writable [ abs "/tmp"; abs "/usr" ]))
  in
  equal string ~msg:"equal policies hash equally" hash_a hash_b;
  is_false ~msg:"different policies hash differently"
    (String.equal hash_a
       (profile_hash (bubblewrap_prepared Confinement.read_only)))

(* Exec sealing *)

let fake_backend =
  Sandbox.Backend.make ~id:"fake"
    ~available:(fun () -> Ok ())
    ~prepare:(fun policy ->
      Ok
        (Sandbox.Backend.prepared ~prefix:[ "fake-wrap" ]
           ~profile:(policy_digest policy)))
    ()

let workspace_policy =
  Confinement.read_only |> Confinement.writable [ abs "/work" ]

let exec_passes_unconfined () =
  let exec = Sandbox.seal Sandbox.Spec.Unconfined in
  let bindings = [ ("ANTHROPIC_API_KEY", "sk") ] in
  (match
     Sandbox.spawn exec ~argv:(argv "sh" [ "-c"; "true" ]) ~env:bindings
   with
  | Ok spawn ->
      equal (list string) ~msg:"argv passes through" [ "sh"; "-c"; "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"unconfined evidence"
        Sandbox.Evidence.not_requested
        (Sandbox.Spawn.evidence spawn);
      equal
        (list (pair string string))
        ~msg:"unconfined inherits the full environment" bindings
        (Sandbox.Spawn.env spawn)
  | Error error -> fail (Sandbox.Error.message error));
  is_true ~msg:"unconfined ignores escalation"
    (match Sandbox.escalation exec with
    | Sandbox.Ignored -> true
    | Sandbox.Available | Sandbox.Denied _ -> false)

let exec_passes_external () =
  let exec = Sandbox.seal Sandbox.Spec.Declared_external in
  match Sandbox.spawn exec ~argv:(argv "true" []) ~env:[] with
  | Ok spawn ->
      equal (list string) ~msg:"argv passes through" [ "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"declared external evidence"
        Sandbox.Evidence.declared_external
        (Sandbox.Spawn.evidence spawn)
  | Error error -> fail (Sandbox.Error.message error)

let exec_fails_closed_by_default () =
  let exec = Sandbox.seal (Sandbox.Spec.Confined workspace_policy) in
  is_true ~msg:"confined without a backend refuses"
    (Result.is_error (Sandbox.spawn exec ~argv:(argv "true" []) ~env:[]))

let exec_seals_confined () =
  let exec =
    Sandbox.seal ~backend:fake_backend (Sandbox.Spec.Confined workspace_policy)
  in
  let bindings = [ ("PATH", "/usr/bin"); ("AWS_SECRET", "x") ] in
  match Sandbox.spawn exec ~argv:(argv "sh" [ "-c"; "true" ]) ~env:bindings with
  | Ok spawn ->
      equal (list string) ~msg:"argv is wrapped"
        [ "fake-wrap"; "sh"; "-c"; "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"enforced evidence carries backend and hash"
        (Sandbox.Evidence.enforced ~backend:"fake"
           ~profile:(policy_digest workspace_policy))
        (Sandbox.Spawn.evidence spawn);
      equal
        (list (pair string string))
        ~msg:"confined strips credentials"
        [ ("PATH", "/usr/bin") ]
        (Sandbox.Spawn.env spawn);
      let _kept, stripped = Sandbox.Env.partition bindings in
      equal (list string) ~msg:"confined reports stripped names"
        [ "AWS_SECRET" ] stripped
  | Error error -> fail (Sandbox.Error.message error)

let exec_escalation_stances () =
  let workspace_write =
    Sandbox.seal ~backend:fake_backend (Sandbox.Spec.Confined workspace_policy)
  in
  is_true ~msg:"workspace-write escalation is available"
    (match Sandbox.escalation workspace_write with
    | Sandbox.Available -> true
    | Sandbox.Denied _ | Sandbox.Ignored -> false);
  let read_only =
    Sandbox.seal ~backend:fake_backend
      (Sandbox.Spec.Confined Confinement.read_only)
  in
  is_true ~msg:"read-only escalation is refused"
    (match Sandbox.escalation read_only with
    | Sandbox.Denied _ -> true
    | Sandbox.Available | Sandbox.Ignored -> false)

let exec_refuses_unavailable_backend_before_preparing () =
  let backend =
    Sandbox.Backend.make ~id:"unavailable"
      ~available:(fun () -> Error (Sandbox.Error.unavailable "not available"))
      ~prepare:(fun policy ->
        fail
          ("prepare must not be called for "
          ^ Format.asprintf "%a" Confinement.pp policy))
      ()
  in
  let exec = Sandbox.seal ~backend (Sandbox.Spec.Confined workspace_policy) in
  match Sandbox.spawn exec ~argv:(argv "true" []) ~env:[] with
  | Error error ->
      equal error_value ~msg:"availability error"
        (Sandbox.Error.unavailable "not available")
        error
  | Ok _ -> fail "unavailable backend must refuse"

let exec_refusal_evidence () =
  let exec = Sandbox.seal (Sandbox.Spec.Confined workspace_policy) in
  match Sandbox.spawn exec ~argv:(argv "true" []) ~env:[] with
  | Error error ->
      begin match Sandbox.Evidence.refused error with
      | Sandbox.Evidence.Refused refused ->
          equal error_value ~msg:"refusal evidence carries error" error refused
      | Sandbox.Evidence.Not_requested | Sandbox.Evidence.Enforced _
      | Sandbox.Evidence.Declared_external ->
          fail "expected refused evidence"
      end
  | Ok _ -> fail "default backend must refuse"

let evidence_json_spelling_is_stable () =
  let profile = Digest.string "canonical" in
  let enforced =
    Sandbox.Evidence.enforced ~backend:"fake" ~profile
    |> Sandbox.Evidence.to_json
  in
  is_true ~msg:"enforced evidence JSON spelling"
    (Json.equal
       (json_obj
          [
            ("kind", Json.string "enforced");
            ("backend", Json.string "fake");
            ("profile_hash", Json.string (Digest.to_hex profile));
          ])
       enforced);
  let error = Sandbox.Error.unavailable "no sandbox backend configured" in
  let refused = Sandbox.Evidence.refused error |> Sandbox.Evidence.to_json in
  is_true ~msg:"refused evidence JSON spelling"
    (match refused with
    | Jsont.Object (fields, _) ->
        Option.is_some (Json.find_mem "reason" fields)
        && Option.is_some (Json.find_mem "error" fields)
    | _ -> false);
  (* The evidence-free postures also carry a stable wire "kind"; nothing else
     pins them, so an accidental respelling would slip past the goldens. *)
  is_true ~msg:"not_requested evidence JSON spelling"
    (Json.equal
       (json_obj [ ("kind", Json.string "not_requested") ])
       (Sandbox.Evidence.to_json Sandbox.Evidence.not_requested));
  is_true ~msg:"declared_external evidence JSON spelling"
    (Json.equal
       (json_obj [ ("kind", Json.string "declared_external") ])
       (Sandbox.Evidence.to_json Sandbox.Evidence.declared_external))

let evidence_cases_are_distinct () =
  let profile = Digest.string "canonical" in
  let error = Sandbox.Error.unavailable "no sandbox backend configured" in
  let cases =
    [
      Sandbox.Evidence.not_requested;
      Sandbox.Evidence.enforced ~backend:"fake" ~profile;
      Sandbox.Evidence.refused error;
      Sandbox.Evidence.declared_external;
    ]
  in
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          if i = j then
            is_true ~msg:"evidence equals itself" (Sandbox.Evidence.equal a b)
          else
            is_false ~msg:"distinct evidence postures are unequal"
              (Sandbox.Evidence.equal a b))
        cases)
    cases;
  is_false ~msg:"enforced differs by backend"
    (Sandbox.Evidence.equal
       (Sandbox.Evidence.enforced ~backend:"a" ~profile)
       (Sandbox.Evidence.enforced ~backend:"b" ~profile));
  is_false ~msg:"enforced differs by profile"
    (Sandbox.Evidence.equal
       (Sandbox.Evidence.enforced ~backend:"a" ~profile)
       (Sandbox.Evidence.enforced ~backend:"a" ~profile:(Digest.string "other")))

(* Seatbelt lowering *)

let seatbelt_policy =
  Confinement.read_only
  |> Confinement.writable [ abs "/work"; abs "/private/tmp" ]
  |> Confinement.protect_meta [ ".git"; ".spice" ]
  |> Confinement.protect [ abs "/work/.spice/store" ]

let seatbelt_profile_shapes () =
  let profile, params = Seatbelt.profile seatbelt_policy in
  is_true ~msg:"profile starts closed"
    (String.includes ~affix:"(deny default)" profile);
  is_true ~msg:"profile allows reads"
    (String.includes ~affix:"(allow file-read*)" profile);
  is_true ~msg:"profile allows writable roots"
    (String.includes ~affix:"(allow file-write*" profile);
  is_true ~msg:"carveouts use literal and subpath"
    (String.includes
       ~affix:"(require-not (literal (param \"WRITABLE_ROOT_1_EXCLUDED_0\")))"
       profile
    && String.includes
         ~affix:"(require-not (subpath (param \"WRITABLE_ROOT_1_EXCLUDED_0\")))"
         profile);
  equal
    (list (pair string string))
    ~msg:"params bind roots and all carveouts beneath each root"
    [
      ("WRITABLE_ROOT_0", "/private/tmp");
      ("WRITABLE_ROOT_0_EXCLUDED_0", "/private/tmp/.git");
      ("WRITABLE_ROOT_0_EXCLUDED_1", "/private/tmp/.spice");
      ("WRITABLE_ROOT_1", "/work");
      ("WRITABLE_ROOT_1_EXCLUDED_0", "/work/.git");
      ("WRITABLE_ROOT_1_EXCLUDED_1", "/work/.spice");
      ("WRITABLE_ROOT_1_EXCLUDED_2", "/work/.spice/store");
    ]
    params;
  is_false ~msg:"restricted network adds no network section"
    (String.includes ~affix:"(allow network-outbound)" profile)

let seatbelt_nested_roots_share_carveouts () =
  (* A workspace nested under another writable root (the temp dir) must not
     have its protected metadata reachable through the enclosing root. *)
  let policy =
    Confinement.read_only
    |> Confinement.writable [ abs "/private/tmp"; abs "/private/tmp/ws" ]
    |> Confinement.protect_meta [ ".git" ]
  in
  let _profile, params = Seatbelt.profile policy in
  is_true ~msg:"enclosing root carves out the nested root's .git"
    (List.exists
       (fun (key, value) ->
         String.equal value "/private/tmp/ws/.git"
         && String.length key >= 15
         && String.equal (String.sub key 0 15) "WRITABLE_ROOT_0")
       params)

let seatbelt_read_only_profile () =
  let profile, params = Seatbelt.profile Confinement.read_only in
  is_false ~msg:"read-only has no write allowance section"
    (String.includes ~affix:"(allow file-write*\n" profile);
  equal (list (pair string string)) ~msg:"read-only binds no params" [] params

let seatbelt_network_enabled () =
  let policy =
    Confinement.read_only |> Confinement.network Confinement.Enabled
  in
  let profile, _params = Seatbelt.profile policy in
  is_true ~msg:"enabled network allows outbound"
    (String.includes ~affix:"(allow network-outbound)" profile);
  is_true ~msg:"enabled network admits TLS platform services"
    (String.includes ~affix:"com.apple.SecurityServer" profile)

let seatbelt_hash policy =
  match Sandbox.Backend.prepare Seatbelt.backend policy with
  | Ok prepared -> profile_hash prepared
  | Error error -> fail (Sandbox.Error.message error)

let seatbelt_hash_is_stable () =
  let hash_a = seatbelt_hash seatbelt_policy in
  let hash_b =
    seatbelt_hash
      (Confinement.read_only
      |> Confinement.protect [ abs "/work/.spice/store" ]
      |> Confinement.protect_meta [ ".spice"; ".git" ]
      |> Confinement.writable [ abs "/private/tmp"; abs "/work" ])
  in
  equal string ~msg:"equal policies hash equally" hash_a hash_b;
  is_false ~msg:"different policies hash differently"
    (String.equal hash_a (seatbelt_hash Confinement.read_only))

let seatbelt_wrap_shape () =
  match Sandbox.Backend.available Seatbelt.backend with
  | Error _ -> () (* not on macOS: wrap shape is covered by profile tests *)
  | Ok () -> (
      match Sandbox.Backend.prepare Seatbelt.backend seatbelt_policy with
      | Error error -> fail (Sandbox.Error.message error)
      | Ok prepared -> (
          let argv =
            Sandbox.Backend.wrap prepared
              ~argv:(argv "/bin/sh" [ "-c"; "true" ])
            |> Sandbox.Argv.to_list
          in
          match argv with
          | exe :: "-p" :: _profile :: rest ->
              equal string ~msg:"absolute sandbox-exec path"
                "/usr/bin/sandbox-exec" exe;
              is_true ~msg:"argv ends with -- command"
                (let rec after_dashes = function
                   | "--" :: tail -> Some tail
                   | _ :: tail -> after_dashes tail
                   | [] -> None
                 in
                 match after_dashes rest with
                 | Some [ "/bin/sh"; "-c"; "true" ] -> true
                 | Some _ | None -> false)
          | _ -> fail "unexpected argv shape"))

let () =
  run "spice.sandbox"
    [
      test "policy combinators normalize" policy_normalizes;
      test "policy validates protected metadata names"
        policy_protect_meta_validates;
      test "policy distinguishes network state" policy_distinguishes_network;
      test "policy computes write carveouts once"
        policy_write_carveouts_are_backend_independent;
      test "env partition strips credential shapes"
        env_partition_strips_credentials;
      test "refusing backend fails closed" backend_none_refuses;
      test "backend validates identity" backend_validates;
      test "backend validates wrapper prefix program"
        backend_prepared_validates_prefix_program;
      test "backend wrappers use non-empty argv" backend_wraps_non_empty_argv;
      test "backend prefix preserves the wrapped command"
        backend_prefix_preserves_command;
      test "bubblewrap backend has stable identity" bubblewrap_backend_identity;
      test "bubblewrap read-only argv shape" bubblewrap_read_only_wrap_shape;
      test "bubblewrap workspace-write argv shape"
        bubblewrap_workspace_write_wrap_shape;
      test "bubblewrap skips missing writable roots"
        bubblewrap_skips_missing_writable_roots;
      test "bubblewrap nested roots share carveouts"
        bubblewrap_nested_roots_share_carveouts;
      test "bubblewrap ignores protected paths outside writable roots"
        bubblewrap_ignores_protected_paths_outside_writable_roots;
      test "bubblewrap carveouts follow writable binds"
        bubblewrap_carveouts_follow_writable_binds;
      test "bubblewrap enabled network keeps host network"
        bubblewrap_network_enabled_keeps_host_network;
      test "bubblewrap profile hash is canonical" bubblewrap_hash_is_stable;
      test "sealing passes unconfined commands through" exec_passes_unconfined;
      test "sealing reports declared external boundaries" exec_passes_external;
      test "sealing fails closed without a backend" exec_fails_closed_by_default;
      test "sealing enforces confined commands" exec_seals_confined;
      test "sealing fixes the escalation stance" exec_escalation_stances;
      test "sealing checks backend availability before prepare"
        exec_refuses_unavailable_backend_before_preparing;
      test "spawn refusal evidence comes from error" exec_refusal_evidence;
      test "evidence JSON spelling is stable" evidence_json_spelling_is_stable;
      test "evidence cases are pairwise distinct" evidence_cases_are_distinct;
      test "seatbelt profile encodes the policy" seatbelt_profile_shapes;
      test "seatbelt nested roots share carveouts"
        seatbelt_nested_roots_share_carveouts;
      test "seatbelt read-only allows no writes" seatbelt_read_only_profile;
      test "seatbelt enabled network opens platform services"
        seatbelt_network_enabled;
      test "seatbelt profile hash is canonical" seatbelt_hash_is_stable;
      test "seatbelt wraps argv around the command" seatbelt_wrap_shape;
    ]
