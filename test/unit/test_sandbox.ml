(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Sandbox = Spice_sandbox
module Policy = Spice_sandbox.Policy
module Seatbelt = Spice_sandbox.Seatbelt
module Bubblewrap = Spice_sandbox.Bubblewrap
module Abs = Spice_path.Abs
module Digest = Spice_digest
module Json = Jsont.Json

let bubblewrap_backend =
  Bubblewrap.make ~probe_executable:Bubblewrap.executable
    ~probe:(fun ~executable ~argv ->
      match Array.to_list argv with
      | program :: _ when String.equal program executable -> Ok ()
      | _ -> Error "probe argv does not start with its executable")
    ()

let abs path = Abs.of_string_exn path
let argv program args = Sandbox.Argv.make ~program args
let argv_list argv = Sandbox.Argv.to_list argv
let profile_hash prepared = Digest.to_hex (Sandbox.Backend.profile prepared)

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let policy_value = testable ~pp:Policy.pp ~equal:Policy.equal ()

let environment ?(path = "/usr/bin:/bin") ?(scratch = abs "/tmp")
    ?(user_names = [])
    ?(launch = fun _ -> None) () =
  match
    Sandbox.Environment.make ~path ~scratch ~user_names ~launch
  with
  | Ok environment -> environment
  | Error error -> fail (Sandbox.Environment.Error.message error)

let confined ?(reads = Policy.All) ?(writable_roots = [])
    ?(protected_paths = [])
    ?(network = Policy.Network.Restricted) () =
  Policy.confined ~reads ~writable_roots ~protected_paths ~network
    ~environment:(environment ())

let evidence_value =
  testable ~pp:Sandbox.Evidence.pp ~equal:Sandbox.Evidence.equal ()

let error_value = testable ~pp:Sandbox.Error.pp ~equal:Sandbox.Error.equal ()
let abs_value = testable ~pp:Abs.pp ~equal:Abs.equal ()

(* Policy *)

let policy_normalizes () =
  let a =
    confined ~writable_roots:[ abs "/work"; abs "/tmp"; abs "/work" ] ()
  in
  let b = confined ~writable_roots:[ abs "/tmp"; abs "/work" ] () in
  equal policy_value ~msg:"writable roots dedup and order canonically" a b;
  equal (list abs_value) ~msg:"accessor reports canonical order"
    [ abs "/tmp"; abs "/work" ]
    (Policy.writable_roots a)

let policy_distinguishes_network () =
  let restricted = confined () in
  let enabled = confined ~network:Policy.Network.Enabled () in
  is_false ~msg:"network state participates in equality"
    (Policy.equal restricted enabled);
  is_true ~msg:"read_only is restricted"
    (match Policy.network restricted with
    | Some Policy.Network.Restricted -> true
    | Some Policy.Network.Enabled | None -> false)

let policy_protected_paths_are_scoped () =
  let policy =
    confined
      ~writable_roots:[ abs "/private/tmp"; abs "/private/tmp/ws" ]
      ~protected_paths:
        [ abs "/outside/.spice"; abs "/private/tmp/ws/.spice" ]
      ()
  in
  equal (list abs_value) ~msg:"protected paths are canonical and scoped"
    [ abs "/private/tmp/ws/.spice" ]
    (Policy.protected_paths policy)

(* Environment *)

let environment_is_exact () =
  let launch = function
    | "LANG" -> Some "en_US.UTF-8"
    | "SPICE_TEST" -> Some "allowed"
    | "ANTHROPIC_API_KEY" -> Some "secret"
    | _ -> None
  in
  let environment = environment ~user_names:[ "SPICE_TEST" ] ~launch () in
  equal (list string) ~msg:"only admitted names are observable"
    [
      "CLICOLOR";
      "CLICOLOR_FORCE";
      "GIT_PAGER";
      "HOME";
      "LANG";
      "LESS";
      "NO_COLOR";
      "PAGER";
      "PATH";
      "SPICE_TEST";
      "TEMP";
      "TERM";
      "TMP";
      "TMPDIR";
    ]
    (Sandbox.Environment.names environment);
  equal
    (list (pair string string))
    ~msg:"scratch bindings and allowed values are exact"
    [
      ("CLICOLOR", "0");
      ("CLICOLOR_FORCE", "0");
      ("GIT_PAGER", "cat");
      ("HOME", "/tmp");
      ("LANG", "en_US.UTF-8");
      ("LESS", "-FRX");
      ("NO_COLOR", "1");
      ("PAGER", "cat");
      ("PATH", "/usr/bin:/bin");
      ("SPICE_TEST", "allowed");
      ("TEMP", "/tmp");
      ("TERM", "dumb");
      ("TMP", "/tmp");
      ("TMPDIR", "/tmp");
    ]
    (Sandbox.Environment.bindings environment)

let environment_rejects_unsafe_shapes () =
  let rejects path user_names launch =
    Result.is_error
      (Sandbox.Environment.make ~path ~scratch:(abs "/scratch") ~user_names
         ~launch)
  in
  is_true ~msg:"relative PATH entry rejected"
    (rejects "/bin:relative" [] (fun _ -> None));
  is_true ~msg:"duplicate user name rejected"
    (rejects "/bin" [ "A"; "A" ] (fun _ -> None));
  is_true ~msg:"reserved user name rejected"
    (rejects "/bin" [ "PATH" ] (fun _ -> None));
  is_true ~msg:"NUL value rejected"
    (rejects "/bin" [ "A" ] (function "A" -> Some "x\000y" | _ -> None))

let environment_omits_invalid_optional_inheritance () =
  let launch = function
    | "OCAML_TOPLEVEL_PATH" -> Some "relative"
    | "LANG" -> Some "bad\000locale"
    | _ -> None
  in
  let names = Sandbox.Environment.names (environment ~launch ()) in
  is_false ~msg:"relative optional toolchain path is omitted"
    (List.mem "OCAML_TOPLEVEL_PATH" names);
  is_false ~msg:"NUL-containing optional locale is omitted"
    (List.mem "LANG" names)

(* Backend *)

let backend_none_refuses () =
  let backend = Sandbox.Backend.none ~reason:"unsupported here" in
  equal string ~msg:"refusing backend id" "none" (Sandbox.Backend.id backend);
  is_true ~msg:"refusing backend is unavailable"
    (Result.is_error (Sandbox.Backend.available backend));
  is_true ~msg:"refusing backend never prepares"
    (Result.is_error (Sandbox.Backend.prepare backend (confined ())))

let policy_digest policy =
  Digest.string (Format.asprintf "%a" Policy.pp policy)

let backend_validates () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () ->
      Sandbox.Backend.make ~id:""
        ~available:(fun () -> Ok ())
        ~prepare:(fun policy ->
          Ok
            (Sandbox.Backend.prepared ~chdir:false ~prefix:[]
               ~profile:(policy_digest policy)))
        ())

let backend_prepared_validates_prefix_program () =
  raises_match
    (function Invalid_argument _ -> true | _ -> false)
    (fun () ->
      Sandbox.Backend.prepared ~chdir:false ~prefix:[ ""; "--" ]
        ~profile:(Digest.string "bad-prefix"))

let backend_wraps_non_empty_argv () =
  let prepared =
    Sandbox.Backend.prepared ~chdir:false ~prefix:[ "fake-wrap" ]
      ~profile:(Digest.string "wrap")
  in
  equal (list string) ~msg:"wrapper receives and returns non-empty argv"
    [ "fake-wrap"; "true"; "--version" ]
    (Sandbox.Backend.wrap prepared ~cwd:(abs "/tmp")
       ~argv:(argv "true" [ "--version" ])
    |> Sandbox.Argv.to_list)

let backend_prefix_preserves_command () =
  let identity =
    Sandbox.Backend.prepared ~chdir:false ~prefix:[]
      ~profile:(Digest.string "identity")
  in
  equal (list string) ~msg:"empty prefix leaves the command unchanged"
    [ "true"; "--version" ]
    (Sandbox.Backend.wrap identity ~cwd:(abs "/tmp")
       ~argv:(argv "true" [ "--version" ])
    |> Sandbox.Argv.to_list);
  let multi =
    Sandbox.Backend.prepared ~chdir:false
      ~prefix:[ "wrapper"; "-p"; "--" ]
      ~profile:(Digest.string "multi")
  in
  equal (list string)
    ~msg:
      "multi-token prefix prepends in order and preserves the command verbatim"
    [ "wrapper"; "-p"; "--"; "cmd"; "a"; "b" ]
    (Sandbox.Backend.wrap multi ~cwd:(abs "/tmp")
       ~argv:(argv "cmd" [ "a"; "b" ])
    |> Sandbox.Argv.to_list)

let bubblewrap_backend_identity () =
  equal string ~msg:"bubblewrap backend id" "linux-bubblewrap"
    (Sandbox.Backend.id bubblewrap_backend)

let bubblewrap_prepared policy =
  match Sandbox.Backend.prepare bubblewrap_backend policy with
  | Ok prepared -> prepared
  | Error error -> fail (Sandbox.Error.message error)

let bubblewrap_wrap policy = function
  | [] -> invalid_arg "test bubblewrap argv must not be empty"
  | program :: args ->
      Sandbox.Backend.wrap
        (bubblewrap_prepared policy)
        ~cwd:(abs "/tmp")
        ~argv:(argv program args)
      |> Sandbox.Argv.to_list

let bubblewrap_policy =
  confined ~writable_roots:[ abs "/usr"; abs "/tmp" ]
    ~protected_paths:
      [ abs "/usr/bin"; abs "/usr/lib"; abs "/usr/share" ]
    ()

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
    bubblewrap_wrap (confined ()) [ "/bin/sh"; "-c"; "true" ]
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
      "--bind";
      "/tmp";
      "/tmp";
      "--unshare-net";
      "--proc";
      "/proc";
      "--chdir";
      "/tmp";
      "--";
      "/bin/sh";
      "-c";
      "true";
    ]
    argv

let bubblewrap_scoped_reads_wrap_shape () =
  let policy =
    Policy.confined
      ~reads:(Policy.Only [ abs "/usr" ])
      ~writable_roots:[ abs "/usr" ]
      ~protected_paths:[ abs "/usr/bin" ]
      ~network:Policy.Network.Restricted
      ~environment:(environment ~scratch:(abs "/tmp") ())
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  equal (list string) ~msg:"scoped-read bubblewrap argv"
    [
      "/usr/bin/bwrap";
      "--new-session";
      "--die-with-parent";
      "--unshare-user";
      "--unshare-pid";
      "--tmpfs";
      "/";
      "--dev";
      "/dev";
      "--ro-bind";
      "/tmp";
      "/tmp";
      "--ro-bind";
      "/usr";
      "/usr";
      "--bind";
      "/tmp";
      "/tmp";
      "--bind";
      "/usr";
      "/usr";
      "--ro-bind";
      "/usr/bin";
      "/usr/bin";
      "--unshare-net";
      "--proc";
      "/proc";
      "--chdir";
      "/tmp";
      "--";
      "true";
    ]
    argv;
  is_false ~msg:"scoped reads never expose the host root"
    (has_sequence [ "--ro-bind"; "/"; "/" ] argv);
  is_false ~msg:"paths outside the read set are absent"
    (List.exists (String.equal "/home") argv)

let bubblewrap_workspace_write_wrap_shape () =
  let argv = bubblewrap_wrap bubblewrap_policy [ "true" ] in
  is_true ~msg:"workspace root is writable"
    (has_sequence [ "--bind"; "/usr"; "/usr" ] argv);
  is_true ~msg:"temp root is writable"
    (has_sequence [ "--bind"; "/tmp"; "/tmp" ] argv);
  is_true ~msg:"protected metadata is restored read-only"
    (has_sequence [ "--ro-bind"; "/usr/bin"; "/usr/bin" ] argv);
  is_true ~msg:"protected store path is restored read-only"
    (has_sequence
       [ "--ro-bind"; "/usr/share"; "/usr/share" ]
       argv)

let bubblewrap_refuses_missing_writable_roots () =
  let missing = Filename.concat (Sys.getcwd ()) ".spice-missing-sandbox-root" in
  let policy = confined ~writable_roots:[ abs missing ] () in
  match Sandbox.Backend.prepare bubblewrap_backend policy with
  | Error error ->
      is_true ~msg:"missing roots are a stale-policy refusal"
        (String.includes ~affix:"sandbox root is stale"
           (Sandbox.Error.message error))
  | Ok _ -> fail "missing writable root unexpectedly prepared"

let bubblewrap_nested_roots_share_carveouts () =
  let root = Filename.temp_dir "spice-sandbox-nested-" "" in
  let protected = Filename.concat root ".git" in
  Unix.mkdir protected 0o700;
  let policy =
    confined ~writable_roots:[ abs root ] ~protected_paths:[ abs protected ] ()
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_true ~msg:"enclosing root carves out nested metadata"
    (has_sequence [ "--ro-bind"; protected; protected ] argv)

let bubblewrap_ignores_protected_paths_outside_writable_roots () =
  let policy =
    confined ~writable_roots:[ abs "/tmp" ]
      ~protected_paths:[ abs "/outside/.spice" ] ()
  in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_false ~msg:"outside protected path is not mounted"
    (has_sequence
       [ "--ro-bind"; "/outside/.spice"; "/outside/.spice" ]
       argv)

let bubblewrap_carveouts_follow_writable_binds () =
  let argv = bubblewrap_wrap bubblewrap_policy [ "true" ] in
  let rec index needle i = function
    | [] -> None
    | value :: rest ->
        if String.equal value needle then Some i else index needle (i + 1) rest
  in
  match (index "--bind" 0 argv, index "/usr/bin" 0 argv) with
  | Some bind, Some carveout ->
      is_true ~msg:"protected overlays come after writable binds"
        (bind < carveout)
  | Some _, None | None, Some _ | None, None ->
      fail "expected bind and carveout"

let bubblewrap_network_enabled_keeps_host_network () =
  let policy = confined ~network:Policy.Network.Enabled () in
  let argv = bubblewrap_wrap policy [ "true" ] in
  is_false ~msg:"enabled network does not unshare net"
    (List.exists (String.equal "--unshare-net") argv)

let bubblewrap_hash_is_stable () =
  let hash_a = profile_hash (bubblewrap_prepared bubblewrap_policy) in
  let hash_b =
    profile_hash
      (bubblewrap_prepared
         (confined
            ~protected_paths:
              [
                abs "/usr/bin";
                abs "/usr/lib";
                abs "/usr/share";
              ]
            ~writable_roots:[ abs "/tmp"; abs "/usr" ] ()))
  in
  equal string ~msg:"equal policies hash equally" hash_a hash_b;
  is_false ~msg:"different policies hash differently"
    (String.equal hash_a
       (profile_hash (bubblewrap_prepared (confined ()))))

(* Exec sealing *)

let fake_backend =
  Sandbox.Backend.make ~id:"fake"
    ~available:(fun () -> Ok ())
    ~prepare:(fun policy ->
      Ok
        (Sandbox.Backend.prepared ~chdir:false ~prefix:[ "fake-wrap" ]
           ~profile:(policy_digest policy)))
    ()

let workspace_policy =
  confined ~writable_roots:[ abs "/tmp" ] ()

let exec_passes_unconfined () =
  let environment = environment () in
  let exec = Sandbox.seal (Policy.direct ~environment) in
  (match
     Sandbox.spawn exec ~cwd:(abs "/tmp")
       ~argv:(argv "sh" [ "-c"; "true" ])
   with
  | Ok spawn ->
      equal (list string) ~msg:"argv passes through" [ "sh"; "-c"; "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"unconfined evidence"
        Sandbox.Evidence.not_requested
        (Sandbox.Spawn.evidence spawn);
      equal
        (list (pair string string))
        ~msg:"direct execution uses the exact environment"
        (Sandbox.Environment.bindings environment)
        (Sandbox.Spawn.env spawn)
  | Error error -> fail (Sandbox.Error.message error));
  is_true ~msg:"unconfined ignores escalation"
    (match Sandbox.escalation exec with
    | Sandbox.Ignored -> true
    | Sandbox.Available | Sandbox.Denied _ -> false)

let exec_passes_external () =
  let environment = environment () in
  let exec = Sandbox.seal (Policy.external_ ~environment) in
  match Sandbox.spawn exec ~cwd:(abs "/tmp") ~argv:(argv "true" []) with
  | Ok spawn ->
      equal (list string) ~msg:"argv passes through" [ "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"declared external evidence"
        Sandbox.Evidence.declared_external
        (Sandbox.Spawn.evidence spawn)
  | Error error -> fail (Sandbox.Error.message error)

let exec_fails_closed_by_default () =
  let exec = Sandbox.seal workspace_policy in
  is_true ~msg:"confined without a backend refuses"
    (Result.is_error
       (Sandbox.spawn exec ~cwd:(abs "/tmp") ~argv:(argv "true" [])))

let exec_seals_confined () =
  let exec =
    Sandbox.seal ~backend:fake_backend workspace_policy
  in
  match
    Sandbox.spawn exec ~cwd:(abs "/tmp")
      ~argv:(argv "sh" [ "-c"; "true" ])
  with
  | Ok spawn ->
      equal abs_value ~msg:"spawn carries canonical cwd"
        (Unix.realpath "/tmp" |> abs)
        (Sandbox.Spawn.cwd spawn);
      equal (list string) ~msg:"argv is wrapped"
        [ "fake-wrap"; "sh"; "-c"; "true" ]
        (Sandbox.Spawn.argv spawn |> argv_list);
      equal evidence_value ~msg:"enforced evidence carries backend and hash"
        (Sandbox.Evidence.enforced ~backend:"fake"
           ~profile:(policy_digest workspace_policy))
        (Sandbox.Spawn.evidence spawn);
      equal
        (list (pair string string))
        ~msg:"confined execution uses the exact environment"
        (Sandbox.Environment.bindings (Policy.environment workspace_policy))
        (Sandbox.Spawn.env spawn)
  | Error error -> fail (Sandbox.Error.message error)

let exec_escalation_stances () =
  let workspace_write =
    Sandbox.seal ~backend:fake_backend workspace_policy
  in
  is_true ~msg:"workspace-write escalation is available"
    (match Sandbox.escalation workspace_write with
    | Sandbox.Available -> true
    | Sandbox.Denied _ | Sandbox.Ignored -> false);
  (match
     Sandbox.spawn_escalated workspace_write ~cwd:(abs "/tmp")
       ~argv:(argv "true" [])
   with
  | Error error -> fail (Sandbox.Error.message error)
  | Ok spawn ->
      equal
        (list (pair string string))
        ~msg:"escalation keeps the exact environment"
        (Sandbox.Environment.bindings (Policy.environment workspace_policy))
        (Sandbox.Spawn.env spawn));
  let read_only =
    Sandbox.seal ~backend:fake_backend (confined ())
  in
  is_true ~msg:"read-only escalation is refused"
    (match Sandbox.escalation read_only with
    | Sandbox.Denied _ -> true
    | Sandbox.Available | Sandbox.Ignored -> false)

let exec_validates_working_directory () =
  let tmp = Unix.realpath "/tmp" |> abs in
  let confined =
    Sandbox.seal ~backend:fake_backend
      (confined ~reads:(Policy.Only [ tmp ]) ())
  in
  is_true ~msg:"cwd outside scoped reads is refused"
    (Result.is_error
       (Sandbox.spawn confined ~cwd:(abs "/") ~argv:(argv "true" [])));
  let direct = Sandbox.seal (Policy.direct ~environment:(environment ())) in
  is_true ~msg:"missing cwd is refused"
    (Result.is_error
       (Sandbox.spawn direct ~cwd:(abs "/spice-missing-cwd")
          ~argv:(argv "true" [])))

let exec_refuses_unavailable_backend_before_preparing () =
  let backend =
    Sandbox.Backend.make ~id:"unavailable"
      ~available:(fun () -> Error (Sandbox.Error.unavailable "not available"))
      ~prepare:(fun policy ->
        fail
          ("prepare must not be called for "
          ^ Format.asprintf "%a" Policy.pp policy))
      ()
  in
  let exec = Sandbox.seal ~backend workspace_policy in
  match Sandbox.spawn exec ~cwd:(abs "/tmp") ~argv:(argv "true" []) with
  | Error error ->
      equal error_value ~msg:"availability error"
        (Sandbox.Error.unavailable "not available")
        error
  | Ok _ -> fail "unavailable backend must refuse"

let exec_refusal_evidence () =
  let exec = Sandbox.seal workspace_policy in
  match Sandbox.spawn exec ~cwd:(abs "/tmp") ~argv:(argv "true" []) with
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
  confined ~writable_roots:[ abs "/usr"; abs "/tmp" ]
    ~protected_paths:
      [ abs "/usr/bin"; abs "/usr/lib"; abs "/usr/share" ]
    ()

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
       ~affix:"(require-not (literal (param \"WRITABLE_ROOT_2_EXCLUDED_0\")))"
       profile
    && String.includes
         ~affix:"(require-not (subpath (param \"WRITABLE_ROOT_2_EXCLUDED_0\")))"
         profile);
  equal
    (list (pair string string))
    ~msg:"params bind roots and all carveouts beneath each root"
    [
      ("WRITABLE_ROOT_0", "/tmp");
      ("WRITABLE_ROOT_1", "/tmp");
      ("WRITABLE_ROOT_2", "/usr");
      ("WRITABLE_ROOT_2_EXCLUDED_0", "/usr/bin");
      ("WRITABLE_ROOT_2_EXCLUDED_1", "/usr/lib");
      ("WRITABLE_ROOT_2_EXCLUDED_2", "/usr/share");
    ]
    params;
  is_false ~msg:"restricted network adds no network section"
    (String.includes ~affix:"(allow network-outbound)" profile)

let seatbelt_nested_roots_share_carveouts () =
  (* A workspace nested under another writable root (the temp dir) must not
     have its protected metadata reachable through the enclosing root. *)
  let policy =
    confined
      ~writable_roots:[ abs "/private/tmp"; abs "/private/tmp/ws" ]
      ~protected_paths:[ abs "/private/tmp/ws/.git" ] ()
  in
  let _profile, params = Seatbelt.profile policy in
  is_true ~msg:"enclosing root carves out the nested root's .git"
    (List.exists
       (fun (key, value) ->
         String.equal value "/private/tmp/ws/.git"
         && String.length key >= 15
         && String.equal (String.sub key 0 15) "WRITABLE_ROOT_1")
       params)

let seatbelt_read_only_profile () =
  let profile, params = Seatbelt.profile (confined ()) in
  is_true ~msg:"read-only permits its private scratch"
    (String.includes ~affix:"(allow file-write*\n" profile);
  equal (list (pair string string)) ~msg:"read-only binds only scratch"
    [ ("WRITABLE_ROOT_0", "/tmp") ] params

let seatbelt_scopes_reads_to_parameters () =
  let policy =
    confined ~reads:(Policy.Only [ abs "/work"; abs "/opt/ocaml" ])
      ~writable_roots:[ abs "/work" ] ()
  in
  let profile, params = Seatbelt.profile policy in
  is_false ~msg:"scoped reads do not include the global read rule"
    (String.includes ~affix:"(allow file-read*)" profile);
  is_true ~msg:"scoped reads admit parameters literally and recursively"
    (String.includes
       ~affix:
         "(literal (param \"READABLE_ROOT_0\")) (subpath (param \
          \"READABLE_ROOT_0\"))"
       profile);
  let readable_params =
    List.filter
      (fun (key, _) -> String.starts_with ~prefix:"READABLE_ROOT_" key)
      params
  in
  equal
    (list (pair string string))
    ~msg:"scoped reads bind every normalized policy root"
    [
      ("READABLE_ROOT_0", "/opt/ocaml");
      ("READABLE_ROOT_1", "/tmp");
      ("READABLE_ROOT_2", "/work");
    ]
    readable_params

let seatbelt_network_enabled () =
  let policy = confined ~network:Policy.Network.Enabled () in
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
      (confined
         ~protected_paths:
           [
             abs "/usr/bin";
             abs "/usr/lib";
             abs "/usr/share";
           ]
         ~writable_roots:[ abs "/tmp"; abs "/usr" ] ())
  in
  equal string ~msg:"equal policies hash equally" hash_a hash_b;
  is_false ~msg:"different policies hash differently"
    (String.equal hash_a (seatbelt_hash (confined ())))

let seatbelt_wrap_shape () =
  match Sandbox.Backend.available Seatbelt.backend with
  | Error _ -> () (* not on macOS: wrap shape is covered by profile tests *)
  | Ok () -> (
      match Sandbox.Backend.prepare Seatbelt.backend seatbelt_policy with
      | Error error -> fail (Sandbox.Error.message error)
      | Ok prepared -> (
          let argv =
            Sandbox.Backend.wrap prepared
              ~cwd:(abs "/tmp")
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
      test "policy distinguishes network state" policy_distinguishes_network;
      test "policy scopes concrete protected paths"
        policy_protected_paths_are_scoped;
      test "environment admits an exact name set" environment_is_exact;
      test "environment rejects unsafe shapes" environment_rejects_unsafe_shapes;
      test "environment omits invalid optional inheritance"
        environment_omits_invalid_optional_inheritance;
      test "refusing backend fails closed" backend_none_refuses;
      test "backend validates identity" backend_validates;
      test "backend validates wrapper prefix program"
        backend_prepared_validates_prefix_program;
      test "backend wrappers use non-empty argv" backend_wraps_non_empty_argv;
      test "backend prefix preserves the wrapped command"
        backend_prefix_preserves_command;
      test "bubblewrap backend has stable identity" bubblewrap_backend_identity;
      test "bubblewrap read-only argv shape" bubblewrap_read_only_wrap_shape;
      test "bubblewrap scoped reads build a closed mount view"
        bubblewrap_scoped_reads_wrap_shape;
      test "bubblewrap workspace-write argv shape"
        bubblewrap_workspace_write_wrap_shape;
      test "bubblewrap refuses missing writable roots"
        bubblewrap_refuses_missing_writable_roots;
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
      test "sealing validates working directories"
        exec_validates_working_directory;
      test "sealing checks backend availability before prepare"
        exec_refuses_unavailable_backend_before_preparing;
      test "spawn refusal evidence comes from error" exec_refusal_evidence;
      test "evidence JSON spelling is stable" evidence_json_spelling_is_stable;
      test "evidence cases are pairwise distinct" evidence_cases_are_distinct;
      test "seatbelt profile encodes the policy" seatbelt_profile_shapes;
      test "seatbelt nested roots share carveouts"
        seatbelt_nested_roots_share_carveouts;
      test "seatbelt read-only writes only private scratch"
        seatbelt_read_only_profile;
      test "seatbelt scopes reads to parameterized policy roots"
        seatbelt_scopes_reads_to_parameters;
      test "seatbelt enabled network opens platform services"
        seatbelt_network_enabled;
      test "seatbelt profile hash is canonical" seatbelt_hash_is_stable;
      test "seatbelt wraps argv around the command" seatbelt_wrap_shape;
    ]
