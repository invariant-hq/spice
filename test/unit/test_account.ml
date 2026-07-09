(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Account = Spice_account
module Credential = Account.Credential
module Json = Jsont.Json
module Kind = Account.Secret.Kind
module Name = Credential.Name
module Org = Account.Org
module Problem = Account.Problem
module Profile = Account.Profile
module Provider = Spice_llm.Provider
module Secret = Account.Secret
module Source = Credential.Source
module Store = Account.Store

let account_value = testable ~pp:Account.pp ~equal:Account.equal ()
let phase_value = testable ~pp:Account.pp_phase ~equal:( = ) ()
let state_value = testable ~pp:Account.State.pp ~equal:( = ) ()
let source_value = testable ~pp:Source.pp ~equal:Source.equal ()
let provider_value = testable ~pp:Provider.pp ~equal:Provider.equal ()
let kind_value = testable ~pp:Kind.pp ~equal:Kind.equal ()
let name_value = testable ~pp:Name.pp ~equal:Name.equal ()
let problem_value = testable ~pp:Problem.pp ~equal:Problem.equal ()
let profile_value = testable ~pp:Profile.pp ~equal:Profile.equal ()
let org_value = testable ~pp:Org.pp ~equal:Org.equal ()

let expect_decode_error_contains msg expected codec json =
  match Json.decode codec json with
  | Error actual -> is_true ~msg (String.includes ~affix:expected actual)
  | Ok _ -> failf "%s: expected decode error" msg

let rec json_contains_string needle = function
  | Jsont.String (value, _) -> String.includes ~affix:needle value
  | Jsont.Object (fields, _) ->
      List.exists (fun (_, value) -> json_contains_string needle value) fields
  | Jsont.Array (values, _) -> List.exists (json_contains_string needle) values
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ -> false

let assert_json_lacks msg secret json =
  is_false ~msg (json_contains_string secret json)

let assert_json_has msg secret json =
  is_true ~msg (json_contains_string secret json)

let provider id = Provider.make id
let openai = provider "openai"
let anthropic = provider "anthropic"
let xai = provider "xai"
let env = Source.env "OPENAI_API_KEY"
let source_name source = Format.asprintf "%a" Source.pp source

type secret_view =
  | Api_key_secret of string
  | Bearer_secret of string
  | OAuth_secret of {
      access_token : string;
      refresh_token : string option;
      expires_at : int64 option;
      account_id : string option;
    }

let pp_string_option ppf = function
  | None -> Format.pp_print_string ppf "None"
  | Some value -> Format.fprintf ppf "Some %S" value

let pp_int64_option ppf = function
  | None -> Format.pp_print_string ppf "None"
  | Some value -> Format.fprintf ppf "Some %Ld" value

let pp_secret_view ppf = function
  | Api_key_secret key -> Format.fprintf ppf "api_key(%S)" key
  | Bearer_secret token -> Format.fprintf ppf "bearer(%S)" token
  | OAuth_secret { access_token; refresh_token; expires_at; account_id } ->
      Format.fprintf ppf "oauth(%S,%a,%a,%a)" access_token pp_string_option
        refresh_token pp_int64_option expires_at pp_string_option account_id

let equal_secret_view a b =
  match (a, b) with
  | Api_key_secret a, Api_key_secret b -> String.equal a b
  | Bearer_secret a, Bearer_secret b -> String.equal a b
  | OAuth_secret a, OAuth_secret b ->
      String.equal a.access_token b.access_token
      && Option.equal String.equal a.refresh_token b.refresh_token
      && Option.equal Int64.equal a.expires_at b.expires_at
      && Option.equal String.equal a.account_id b.account_id
  | (Api_key_secret _ | Bearer_secret _ | OAuth_secret _), _ -> false

let secret_view_value = testable ~pp:pp_secret_view ~equal:equal_secret_view ()

let secret_view secret =
  Secret.expose secret
    ~api_key:(fun ~key -> Api_key_secret key)
    ~bearer:(fun ~token -> Bearer_secret token)
    ~oauth:(fun ~access_token ~refresh_token ~expires_at ~account_id ->
      OAuth_secret { access_token; refresh_token; expires_at; account_id })

type binding_view = {
  provider : Provider.t;
  name : string;
  secret : secret_view;
}

let pp_binding_view ppf binding =
  Format.fprintf ppf "{provider=%a; name=%S; secret=%a}" Provider.pp
    binding.provider binding.name pp_secret_view binding.secret

let equal_binding_view a b =
  Provider.equal a.provider b.provider
  && String.equal a.name b.name
  && equal_secret_view a.secret b.secret

let binding_view_value =
  testable ~pp:pp_binding_view ~equal:equal_binding_view ()

let binding_view (provider, name, secret) =
  { provider; name = Name.to_string name; secret = secret_view secret }

let secret_json kind fields = json_object (("kind", Json.string kind) :: fields)

let store_json ?(version = 1) ?(extra = []) credentials =
  json_object
    ([ ("version", Json.int version); ("credentials", json_object credentials) ]
    @ extra)

let source_json kind fields = json_object (("kind", Json.string kind) :: fields)

let account_json ?(version = 1) ?(extra = []) fields =
  json_object
    ([ ("version", Json.int version); ("provider", Json.string "openai") ]
    @ fields @ extra)

let availability_string = function
  | `Available -> "available"
  | `Unavailable -> "unavailable"
  | `Unknown -> "unknown"

let source_and_name_contracts () =
  equal source_value ~msg:"process source" Source.process Source.process;
  equal source_value ~msg:"env source" env (Source.env "OPENAI_API_KEY");
  equal source_value ~msg:"default store source" (Source.store ())
    (Source.store ~name:Name.default ());
  equal source_value ~msg:"named store source"
    (Source.store ~name:(Name.make "work") ())
    (Source.store ~name:(Name.make "work") ());
  expect_invalid_arg "env name cannot be empty" (fun () -> Source.env "");
  expect_invalid_arg "env name cannot start with digit" (fun () ->
      Source.env "1TOKEN");
  expect_invalid_arg "env name rejects hyphen" (fun () -> Source.env "BAD-NAME");
  expect_invalid_arg "store name cannot be empty" (fun () ->
      Source.store ~name:(Name.make "") ());
  equal name_value ~msg:"default credential name" Name.default
    (Name.make "default");
  equal string ~msg:"name storage spelling" "work.account"
    (Name.to_string (Name.make "work.account"));
  is_true ~msg:"credential names compare by spelling"
    (Name.compare (Name.make "personal") (Name.make "work") < 0);
  expect_invalid_arg "credential name cannot be empty" (fun () -> Name.make "");
  expect_invalid_arg "credential name rejects slash" (fun () ->
      Name.make "bad/name");
  is_true ~msg:"source pp is diagnostic text"
    (not (String.is_empty (source_name env)));
  (* tag and name are the derived display facts the CLI/TUI surfaces share. *)
  is_true ~msg:"process tag" (Source.tag Source.process = `Process);
  is_true ~msg:"env tag" (Source.tag env = `Env);
  is_true ~msg:"store tag" (Source.tag (Source.store ()) = `Store);
  equal (option string) ~msg:"process source has no name" None
    (Source.name Source.process);
  equal (option string) ~msg:"env source name is the variable"
    (Some "OPENAI_API_KEY") (Source.name env);
  equal (option string) ~msg:"default store source name" (Some "default")
    (Source.name (Source.store ()));
  equal (option string) ~msg:"named store source name is its spelling"
    (Some "work")
    (Source.name (Source.store ~name:(Name.make "work") ()))

let secret_contracts () =
  let key = Secret.api_key "sk-test" in
  let token = Secret.bearer "bearer-test" in
  let oauth =
    Secret.oauth ~access_token:"access" ~refresh_token:"refresh"
      ~expires_at:123L ~account_id:"acct" ()
  in
  equal kind_value ~msg:"api key kind" Kind.Api_key (Secret.kind key);
  equal kind_value ~msg:"bearer kind" Kind.Bearer (Secret.kind token);
  equal kind_value ~msg:"oauth kind" Kind.OAuth (Secret.kind oauth);
  equal secret_view_value ~msg:"api key expose" (Api_key_secret "sk-test")
    (secret_view key);
  equal secret_view_value ~msg:"bearer expose" (Bearer_secret "bearer-test")
    (secret_view token);
  equal secret_view_value ~msg:"oauth expose"
    (OAuth_secret
       {
         access_token = "access";
         refresh_token = Some "refresh";
         expires_at = Some 123L;
         account_id = Some "acct";
       })
    (secret_view oauth);
  (* has_refresh_token is a credential-free fact lifted out of [expose] so the
     refresh scheduler never opens the CPS gate just to test presence. *)
  is_true ~msg:"oauth with a refresh token" (Secret.has_refresh_token oauth);
  is_false ~msg:"oauth without a refresh token"
    (Secret.has_refresh_token (Secret.oauth ~access_token:"access" ()));
  is_false ~msg:"api key never carries a refresh token"
    (Secret.has_refresh_token key);
  is_false ~msg:"bearer never carries a refresh token"
    (Secret.has_refresh_token token);
  expect_invalid_arg "api key cannot be empty" (fun () -> Secret.api_key "");
  expect_invalid_arg "bearer cannot be empty" (fun () -> Secret.bearer "");
  expect_invalid_arg "oauth access token cannot be empty" (fun () ->
      Secret.oauth ~access_token:"" ());
  expect_invalid_arg "oauth refresh token cannot be empty" (fun () ->
      Secret.oauth ~access_token:"access" ~refresh_token:"" ());
  expect_invalid_arg "oauth account id cannot be empty" (fun () ->
      Secret.oauth ~access_token:"access" ~account_id:"" ());
  expect_invalid_arg "oauth expiry cannot be negative" (fun () ->
      Secret.oauth ~access_token:"access" ~expires_at:(-1L) ())

let credential_contracts () =
  let key =
    Credential.make ~provider:openai ~source:env (Secret.api_key "sk-test")
  in
  let token =
    Credential.make ~provider:anthropic ~source:Source.process
      (Secret.bearer "bearer-test")
  in
  let oauth =
    Credential.make ~provider:xai
      ~source:(Source.store ~name:(Name.make "work") ())
      (Secret.oauth ~access_token:"access" ~refresh_token:"refresh" ())
  in
  equal provider_value ~msg:"provider accessor" openai (Credential.provider key);
  equal source_value ~msg:"source accessor" env (Credential.source key);
  equal kind_value ~msg:"api key kind" Kind.Api_key (Credential.kind key);
  equal kind_value ~msg:"bearer kind" Kind.Bearer (Credential.kind token);
  equal kind_value ~msg:"oauth kind" Kind.OAuth (Credential.kind oauth);
  equal secret_view_value ~msg:"secret accessor"
    (OAuth_secret
       {
         access_token = "access";
         refresh_token = Some "refresh";
         expires_at = None;
         account_id = None;
       })
    (oauth |> Credential.secret |> secret_view);
  equal (option secret_view_value) ~msg:"first matching provider wins"
    (Some (secret_view (Credential.secret key)))
    (Account.resolve [ token; key ] openai
    |> Option.map Credential.secret
    |> Option.map secret_view);
  equal (option secret_view_value) ~msg:"missing provider does not resolve" None
    (Account.resolve [ token; key ] xai
    |> Option.map Credential.secret
    |> Option.map secret_view)

let store_contracts () =
  let personal = Name.make "personal" in
  let work = Name.make "work" in
  let openai_default = Secret.api_key "sk-default" in
  let openai_work = Secret.bearer "work-token" in
  let anthropic_default =
    Secret.oauth ~access_token:"anthropic-access"
      ~refresh_token:"anthropic-refresh" ~expires_at:456L ()
  in
  let store =
    Store.of_list
      [
        (openai, work, openai_work);
        (anthropic, Name.default, anthropic_default);
        (openai, personal, openai_default);
      ]
  in
  equal (list string) ~msg:"names are deterministic" [ "personal"; "work" ]
    (Store.names store ~provider:openai |> List.map Name.to_string);
  equal (option secret_view_value) ~msg:"secret lookup by name"
    (Some (secret_view openai_work))
    (Store.secret store ~provider:openai ~name:work () |> Option.map secret_view);
  equal (option source_value)
    ~msg:"credential projection carries store source name"
    (Some (Source.store ~name:(Name.make "work") ()))
    (Store.credential store ~provider:openai ~name:work ()
    |> Option.map Credential.source);
  equal (list binding_view_value) ~msg:"bindings are provider/name ordered"
    [
      binding_view (anthropic, Name.default, anthropic_default);
      binding_view (openai, personal, openai_default);
      binding_view (openai, work, openai_work);
    ]
    (Store.bindings store |> List.map binding_view);
  equal (list string) ~msg:"filtered bindings" [ "personal"; "work" ]
    (Store.bindings ~provider:openai store
    |> List.map (fun (_, name, _) -> Name.to_string name));
  let replaced =
    store
    |> Store.set ~provider:openai ~name:work (Secret.api_key "sk-work-new")
  in
  equal (option secret_view_value) ~msg:"set replaces provider/name"
    (Some (Api_key_secret "sk-work-new"))
    (Store.secret replaced ~provider:openai ~name:work ()
    |> Option.map secret_view);
  let defaulted =
    Store.empty |> Store.set ~provider:openai (Secret.bearer "default-token")
  in
  equal (list string) ~msg:"set defaults name" [ "default" ]
    (Store.names defaulted ~provider:openai |> List.map Name.to_string);
  equal (list string) ~msg:"remove deletes one binding" [ "personal" ]
    (Store.remove store ~provider:openai ~name:work ()
    |> Store.names ~provider:openai
    |> List.map Name.to_string);
  expect_invalid_arg "of_list rejects duplicate provider/name" (fun () ->
      Store.of_list
        [
          (openai, Name.default, Secret.api_key "one");
          (openai, Name.default, Secret.api_key "two");
        ])

let store_json_contracts () =
  let store =
    Store.empty
    |> Store.set ~provider:openai (Secret.api_key "sk-store")
    |> Store.set ~provider:openai ~name:(Name.make "work")
         (Secret.bearer "bearer-store")
    |> Store.set ~provider:anthropic
         (Secret.oauth ~access_token:"access-store"
            ~refresh_token:"refresh-store" ())
  in
  let json = encode Store.jsont store in
  assert_json_has "store JSON includes API key" "sk-store" json;
  assert_json_has "store JSON includes bearer" "bearer-store" json;
  assert_json_has "store JSON includes OAuth access token" "access-store" json;
  assert_json_has "store JSON includes OAuth refresh token" "refresh-store" json;
  equal (list binding_view_value) ~msg:"store JSON roundtrip"
    (Store.bindings store |> List.map binding_view)
    (json |> decode Store.jsont |> Store.bindings |> List.map binding_view);
  expect_decode_error_contains "store rejects unknown version"
    "unsupported account store version" Store.jsont (store_json ~version:2 []);
  expect_decode_error_contains "store rejects old accounts shape"
    "unknown field accounts" Store.jsont
    (json_object
       [
         ("version", Json.int 1);
         ( "accounts",
           json_object
             [
               ( "openai",
                 json_object
                   [
                     ( "credential",
                       secret_json "api_key" [ ("api_key", Json.string "sk") ]
                     );
                   ] );
             ] );
       ]);
  expect_decode_error_contains "store rejects unknown fields"
    "unknown field unexpected" Store.jsont
    (store_json ~extra:[ ("unexpected", Json.bool true) ] []);
  expect_decode_error_contains "store rejects non-object provider credentials"
    "credentials for provider openai must be an object" Store.jsont
    (store_json [ ("openai", Json.string "bad") ]);
  expect_decode_error_contains "store rejects duplicate provider field"
    "duplicate field openai" Store.jsont
    (store_json [ ("openai", json_object []); ("openai", json_object []) ]);
  expect_decode_error_contains "store rejects invalid provider ids"
    "id must start with a lowercase ASCII letter" Store.jsont
    (store_json [ ("OpenAI", json_object []) ]);
  expect_decode_error_contains "store rejects invalid credential names"
    "name is invalid" Store.jsont
    (store_json
       [
         ( "openai",
           json_object
             [
               ( "bad/name",
                 secret_json "api_key" [ ("api_key", Json.string "sk") ] );
             ] );
       ]);
  expect_decode_error_contains "store rejects unknown credential kind"
    "unknown credential kind" Store.jsont
    (store_json
       [
         ( "openai",
           json_object
             [
               ("default", secret_json "session" [ ("token", Json.string "x") ]);
             ] );
       ]);
  expect_decode_error_contains "store rejects malformed OAuth"
    "access_token must be a string" Store.jsont
    (store_json
       [
         ( "openai",
           json_object
             [
               ( "default",
                 secret_json "oauth" [ ("access_token", Json.null ()) ] );
             ] );
       ]);
  expect_decode_error_contains "store rejects negative OAuth expiry"
    "expires_at must not be negative" Store.jsont
    (store_json
       [
         ( "openai",
           json_object
             [
               ( "default",
                 secret_json "oauth"
                   [
                     ("access_token", Json.string "access");
                     ("expires_at", Json.int64 (-1L));
                   ] );
             ] );
       ])

let profile_org_problem_contracts () =
  let profile =
    Profile.make ~id:"acct" ~email:"user@example.com" ~name:"User" ()
  in
  equal profile_value ~msg:"profile equality" profile
    (Profile.make ~id:"acct" ~email:"user@example.com" ~name:"User" ());
  expect_invalid_arg "profile needs one field" (fun () -> Profile.make ());
  expect_invalid_arg "profile rejects empty field" (fun () ->
      Profile.make ~email:"" ());
  let org = Org.make ~id:"org" ~name:"Engineering" () in
  equal org_value ~msg:"org equality" org
    (Org.make ~id:"org" ~name:"Engineering" ());
  expect_invalid_arg "org id cannot be empty" (fun () -> Org.make ~id:"" ());
  expect_invalid_arg "org name cannot be empty" (fun () ->
      Org.make ~id:"org" ~name:"" ());
  let builtins =
    [
      Problem.Invalid_credential;
      Problem.Expired_credential;
      Problem.Refresh_failed;
      Problem.Revoked;
      Problem.Wrong_account;
      Problem.Wrong_organization;
      Problem.Rate_limited;
      Problem.Quota_exceeded;
      Problem.Network;
      Problem.Unsupported;
    ]
  in
  List.iter
    (fun problem ->
      let label = Problem.to_string problem in
      equal (option problem_value)
        ~msg:("problem string " ^ label)
        (Some problem) (Problem.of_string label))
    builtins;
  equal (option problem_value) ~msg:"unknown valid problem"
    (Some (Problem.other "maintenance_window"))
    (Problem.of_string "maintenance_window");
  equal (list string) ~msg:"problem compare orders by storage spelling"
    [ "network"; "rate_limited"; "unsupported" ]
    (List.sort Problem.compare
       [ Problem.Unsupported; Problem.Rate_limited; Problem.Network ]
    |> List.map Problem.to_string);
  List.iter
    (fun label ->
      equal (option problem_value)
        ~msg:("invalid problem label " ^ label)
        None (Problem.of_string label))
    [ ""; "_a"; "A"; "a-b"; "bad.label" ];
  expect_invalid_arg "other rejects invalid labels" (fun () ->
      Problem.other "Bad-Label");
  expect_invalid_arg "other rejects reserved labels" (fun () ->
      Problem.other "network")

let account_status_contracts () =
  let credential =
    Credential.make ~provider:openai ~source:env (Secret.api_key "sk-secret")
  in
  let missing = Account.missing ~provider:openai in
  equal provider_value ~msg:"missing provider" openai (Account.provider missing);
  equal state_value ~msg:"missing state" Account.State.Missing
    (Account.state missing);
  equal string ~msg:"missing state string" "missing"
    (Account.State.to_string (Account.state missing));
  equal (option source_value) ~msg:"missing source" None
    (Account.source missing);
  equal (option kind_value) ~msg:"missing credential kind" None
    (Account.credential_kind missing);
  equal (list problem_value) ~msg:"missing problems" []
    (Account.problems missing);
  let present = Account.present credential in
  equal state_value ~msg:"present state" Account.State.Present
    (Account.state present);
  equal string ~msg:"present state string" "present"
    (Account.State.to_string (Account.state present));
  equal (option source_value) ~msg:"present source" (Some env)
    (Account.source present);
  equal (option kind_value) ~msg:"present credential kind" (Some Kind.Api_key)
    (Account.credential_kind present);
  is_false ~msg:"present pp excludes secret"
    (String.includes ~affix:"sk-secret"
       (Format.asprintf "%a" Account.pp present));
  let profile = Profile.make ~email:"user@example.com" () in
  let org = Org.make ~id:"org" () in
  let checked =
    Account.checked credential ~at:42L ~profile ~org
      ~problems:
        [
          Problem.Network;
          Problem.Rate_limited;
          Problem.Network;
          Problem.other "maintenance";
        ]
      ()
  in
  equal state_value ~msg:"checked state" Account.State.Checked
    (Account.state checked);
  equal string ~msg:"checked state string" "checked"
    (Account.State.to_string (Account.state checked));
  equal (option int64) ~msg:"checked timestamp" (Some 42L)
    (Account.checked_at checked);
  equal (option profile_value) ~msg:"checked profile" (Some profile)
    (Account.profile checked);
  equal (option org_value) ~msg:"checked org" (Some org) (Account.org checked);
  equal (list string) ~msg:"problems sorted and deduplicated"
    [ "maintenance"; "network"; "rate_limited" ]
    (Account.problems checked |> List.map Problem.to_string);
  equal account_value ~msg:"account equality normalizes problems" checked
    (Account.checked credential ~at:42L ~profile ~org
       ~problems:
         [ Problem.other "maintenance"; Problem.Rate_limited; Problem.Network ]
       ());
  expect_invalid_arg "checked timestamp cannot be negative" (fun () ->
      Account.checked credential ~at:(-1L) ())

let account_model_contracts () =
  let credential =
    Credential.make ~provider:openai ~source:env (Secret.api_key "sk-test-f234")
  in
  let missing = Account.missing ~provider:openai in
  let present = Account.present credential in
  equal
    (option (list string))
    ~msg:"missing has unknown model set" None (Account.models missing);
  equal
    (option (list string))
    ~msg:"present has unknown model set" None (Account.models present);
  equal string ~msg:"missing model availability is unknown" "unknown"
    (availability_string (Account.model_available missing "gpt-a"));
  let checked =
    Account.checked credential ~models:[ "gpt-b"; "gpt-a"; "gpt-b" ] ()
  in
  equal phase_value ~msg:"model availability does not affect phase" `Ready
    (Account.phase checked);
  equal
    (option (list string))
    ~msg:"models are sorted and deduplicated"
    (Some [ "gpt-a"; "gpt-b" ])
    (Account.models checked);
  equal string ~msg:"listed model is available" "available"
    (availability_string (Account.model_available checked "gpt-a"));
  equal string ~msg:"unlisted model is unavailable" "unavailable"
    (availability_string (Account.model_available checked "gpt-c"));
  equal account_value ~msg:"model JSON roundtrip" checked
    (checked |> encode Account.jsont |> decode Account.jsont)

let account_json_contracts () =
  let missing = Account.missing ~provider:openai in
  equal account_value ~msg:"missing JSON roundtrip" missing
    (missing |> encode Account.jsont |> decode Account.jsont);
  let present_secret = "sk-present-secret" in
  let present =
    Account.present
      (Credential.make ~provider:openai ~source:env
         (Secret.api_key present_secret))
  in
  let present_json = encode Account.jsont present in
  assert_json_lacks "present JSON excludes secret" present_secret present_json;
  equal account_value ~msg:"present JSON roundtrip" present
    (decode Account.jsont present_json);
  let checked_secret = "access-secret" in
  let checked =
    Account.checked
      (Credential.make ~provider:openai
         ~source:(Source.store ~name:(Name.make "oauth") ())
         (Secret.oauth ~access_token:checked_secret ()))
      ~at:7L
      ~profile:(Profile.make ~id:"acct" ())
      ~problems:[ Problem.Expired_credential ]
      ()
  in
  let checked_json = encode Account.jsont checked in
  assert_json_lacks "checked JSON excludes OAuth access token" checked_secret
    checked_json;
  equal account_value ~msg:"checked JSON roundtrip" checked
    (decode Account.jsont checked_json);
  expect_decode_error_contains "account rejects unknown version"
    "unsupported account version" Account.jsont
    (account_json ~version:2 [ ("state", Json.string "missing") ]);
  expect_decode_error_contains "account rejects unknown state"
    "unknown account state: stale" Account.jsont
    (account_json [ ("state", Json.string "stale") ]);
  expect_decode_error_contains "account rejects old state shape"
    "account field state must be a string" Account.jsont
    (json_object
       [
         ("version", Json.int 1);
         ("provider", Json.string "openai");
         ("state", json_object [ ("kind", Json.string "missing") ]);
       ]);
  expect_decode_error_contains "missing rejects credential facts"
    "field source is not allowed" Account.jsont
    (account_json
       [
         ("state", Json.string "missing"); ("source", source_json "process" []);
       ]);
  expect_decode_error_contains "missing rejects model facts"
    "field models is not allowed" Account.jsont
    (account_json
       [
         ("state", Json.string "missing");
         ("models", json_array [ Json.string "gpt-a" ]);
       ]);
  expect_decode_error_contains "present requires source"
    "requires object field source" Account.jsont
    (account_json
       [
         ("state", Json.string "present");
         ("credential_kind", Json.string "api_key");
       ]);
  expect_decode_error_contains "present rejects model facts"
    "field models is not allowed" Account.jsont
    (account_json
       [
         ("state", Json.string "present");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("models", json_array [ Json.string "gpt-a" ]);
       ]);
  expect_decode_error_contains "checked requires problems"
    "requires array field problems" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "env" [ ("name", Json.string "OPENAI_API_KEY") ]);
         ("credential_kind", Json.string "api_key");
       ]);
  expect_decode_error_contains "checked rejects negative checked_at"
    "checked_at must not be negative" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("checked_at", Json.int64 (-1L));
       ]);
  expect_decode_error_contains "checked rejects invalid problem label"
    "invalid account problem label" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array [ Json.string "Bad-Label" ]);
       ]);
  expect_decode_error_contains "checked rejects empty profile"
    "at least one field is required" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("profile", json_object []);
       ]);
  expect_decode_error_contains "checked profile must be object"
    "field profile must be an object" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("profile", Json.string "acct");
       ]);
  expect_decode_error_contains "checked org requires id"
    "requires string field id" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("org", json_object []);
       ]);
  expect_decode_error_contains "checked models must be array"
    "field models must be an array" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("models", Json.string "gpt-a");
       ]);
  expect_decode_error_contains "checked models must contain strings"
    "field models must be an array of strings" Account.jsont
    (account_json
       [
         ("state", Json.string "checked");
         ("source", source_json "process" []);
         ("credential_kind", Json.string "api_key");
         ("problems", json_array []);
         ("models", json_array [ Json.int 1 ]);
       ]);
  expect_decode_error_contains "source rejects old store label field"
    "unknown field label" Account.jsont
    (account_json
       [
         ("state", Json.string "present");
         ( "source",
           source_json "store"
             [ ("name", Json.string "default"); ("label", Json.string "old") ]
         );
         ("credential_kind", Json.string "api_key");
       ])

let fingerprint_contracts () =
  equal (option string) ~msg:"api key fingerprint is last 4 characters"
    (Some "f234")
    (Secret.fingerprint (Secret.api_key "sk-test-f234"));
  equal (option string) ~msg:"bearer fingerprint is last 4 characters"
    (Some "edcb")
    (Secret.fingerprint (Secret.bearer "token-edcb"));
  equal (option string) ~msg:"short api key has no fingerprint" None
    (Secret.fingerprint (Secret.api_key "short"));
  equal (option string) ~msg:"7-character material has no fingerprint" None
    (Secret.fingerprint (Secret.api_key "1234567"));
  equal (option string) ~msg:"8-character material has a fingerprint"
    (Some "5678")
    (Secret.fingerprint (Secret.api_key "12345678"));
  equal (option string) ~msg:"oauth fingerprint prefers account id"
    (Some "acct-1")
    (Secret.fingerprint
       (Secret.oauth ~access_token:"access-token-9999" ~account_id:"acct-1" ()));
  equal (option string) ~msg:"oauth fingerprint falls back to access token"
    (Some "9999")
    (Secret.fingerprint (Secret.oauth ~access_token:"access-token-9999" ()));
  equal (option string) ~msg:"credential fingerprint is secret fingerprint"
    (Some "f234")
    (Credential.fingerprint
       (Credential.make ~provider:openai ~source:env
          (Secret.api_key "sk-test-f234")));
  equal (option int64) ~msg:"api key has no expiry" None
    (Secret.expires_at (Secret.api_key "sk-test-f234"));
  equal (option int64) ~msg:"oauth without expiry" None
    (Secret.expires_at (Secret.oauth ~access_token:"access-token-9999" ()));
  equal (option int64) ~msg:"oauth expiry metadata" (Some 99L)
    (Secret.expires_at
       (Secret.oauth ~access_token:"access-token-9999" ~expires_at:99L ()))

let phase_contracts () =
  let fatal =
    [
      Problem.Invalid_credential;
      Problem.Expired_credential;
      Problem.Refresh_failed;
      Problem.Revoked;
      Problem.Wrong_account;
      Problem.Wrong_organization;
    ]
  in
  let non_fatal =
    [
      Problem.Rate_limited;
      Problem.Quota_exceeded;
      Problem.Network;
      Problem.Unsupported;
      Problem.other "maintenance";
    ]
  in
  List.iter
    (fun problem ->
      is_true
        ~msg:("fatal problem " ^ Problem.to_string problem)
        (Problem.fatal problem))
    fatal;
  List.iter
    (fun problem ->
      is_false
        ~msg:("non-fatal problem " ^ Problem.to_string problem)
        (Problem.fatal problem))
    non_fatal;
  List.iter
    (fun problem ->
      is_true
        ~msg:("transient problem " ^ Problem.to_string problem)
        (Problem.transient problem))
    [ Problem.Network; Problem.Rate_limited ];
  List.iter
    (fun problem ->
      is_false
        ~msg:("non-transient problem " ^ Problem.to_string problem)
        (Problem.transient problem))
    (fatal @ [ Problem.Quota_exceeded; Problem.Unsupported ]);
  let credential =
    Credential.make ~provider:openai ~source:env (Secret.api_key "sk-test-f234")
  in
  equal phase_value ~msg:"missing phase" `Missing
    (Account.phase (Account.missing ~provider:openai));
  equal phase_value ~msg:"present phase" `Unchecked
    (Account.phase (Account.present credential));
  equal phase_value ~msg:"checked without problems is ready" `Ready
    (Account.phase (Account.checked credential ()));
  equal phase_value ~msg:"transient problems degrade" `Degraded
    (Account.phase
       (Account.checked credential ~problems:[ Problem.Network ] ()));
  equal phase_value ~msg:"quota degrades" `Degraded
    (Account.phase
       (Account.checked credential ~problems:[ Problem.Quota_exceeded ] ()));
  equal phase_value ~msg:"unknown problems degrade" `Degraded
    (Account.phase
       (Account.checked credential ~problems:[ Problem.other "maintenance" ] ()));
  equal phase_value ~msg:"fatal problem blocks" `Blocked
    (Account.phase
       (Account.checked credential ~problems:[ Problem.Revoked ] ()));
  equal phase_value ~msg:"any fatal problem blocks among degraded ones" `Blocked
    (Account.phase
       (Account.checked credential
          ~problems:[ Problem.Quota_exceeded; Problem.Invalid_credential ]
          ()));
  equal string ~msg:"phase storage spelling" "degraded"
    (Account.phase_to_string `Degraded)

let () =
  run "spice.account"
    [
      test "source and name contracts" source_and_name_contracts;
      test "secret contracts" secret_contracts;
      test "credential contracts" credential_contracts;
      test "fingerprint contracts" fingerprint_contracts;
      test "store contracts" store_contracts;
      test "store JSON contracts" store_json_contracts;
      test "profile org problem contracts" profile_org_problem_contracts;
      test "phase contracts" phase_contracts;
      test "account status contracts" account_status_contracts;
      test "account model contracts" account_model_contracts;
      test "account JSON contracts" account_json_contracts;
    ]
