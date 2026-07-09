(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Account = Spice_account
module Auth = Spice_provider.Auth
module Capability = Spice_provider.Model.Capability
module Date = Spice_provider.Model.Date
module Env = Auth.Env
module Login = Auth.Login
module Llm_model = Spice_llm.Model
module Llm_provider = Spice_llm.Provider
module Modality = Spice_provider.Model.Modality
module Model = Spice_provider.Model
module Options = Spice_llm.Request.Options
module Usage = Spice_llm.Usage
module Provider = Spice_provider
module Catalog = Spice_provider.Catalog
module Selector = Spice_provider.Selector
module Secret = Account.Secret

let provider_value = testable ~pp:Llm_provider.pp ~equal:Llm_provider.equal ()
let llm_model_value = testable ~pp:Llm_model.pp ~equal:Llm_model.equal ()

let equal_catalog_error a b =
  match (a, b) with
  | ( Catalog.Lookup_error.Invalid_selector a,
      Catalog.Lookup_error.Invalid_selector b ) ->
      String.equal a.input b.input
      && String.equal a.message b.message
      && List.equal String.equal a.candidates b.candidates
  | ( Catalog.Lookup_error.Unknown_provider a,
      Catalog.Lookup_error.Unknown_provider b ) ->
      Llm_provider.equal a.provider b.provider
      && List.equal String.equal a.known b.known
  | Catalog.Lookup_error.Unknown_model a, Catalog.Lookup_error.Unknown_model b
    ->
      Llm_provider.equal a.provider b.provider
      && String.equal a.model b.model
      && List.equal String.equal a.known b.known
  | ( ( Catalog.Lookup_error.Invalid_selector _
      | Catalog.Lookup_error.Unknown_provider _
      | Catalog.Lookup_error.Unknown_model _ ),
      ( Catalog.Lookup_error.Invalid_selector _
      | Catalog.Lookup_error.Unknown_provider _
      | Catalog.Lookup_error.Unknown_model _ ) ) ->
      false

let catalog_error_value =
  testable ~pp:Catalog.Lookup_error.pp ~equal:equal_catalog_error ()

let date_value = testable ~pp:Date.pp ~equal:Date.equal ()
let modality_value = testable ~pp:Modality.pp ~equal:Modality.equal ()
let capability_value = testable ~pp:Capability.pp ~equal:Capability.equal ()
let float_value = testable ~pp:Format.pp_print_float ~equal:Float.equal ()

let kind_value =
  testable ~pp:Account.Secret.Kind.pp ~equal:Account.Secret.Kind.equal ()

let assert_lacks msg secret text =
  is_false ~msg (String.includes ~affix:secret text)

let expect_error msg testable expected result =
  match result with
  | Ok value ->
      ignore value;
      failf "%s: expected Error" msg
  | Error error -> equal testable ~msg expected error

type secret_view =
  | Api_key of string
  | Bearer of string
  | OAuth of {
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
  | Api_key key -> Format.fprintf ppf "api_key(%S)" key
  | Bearer token -> Format.fprintf ppf "bearer(%S)" token
  | OAuth { access_token; refresh_token; expires_at; account_id } ->
      Format.fprintf ppf "oauth(%S,%a,%a,%a)" access_token pp_string_option
        refresh_token pp_int64_option expires_at pp_string_option account_id

let equal_secret_view a b =
  match (a, b) with
  | Api_key a, Api_key b -> String.equal a b
  | Bearer a, Bearer b -> String.equal a b
  | OAuth a, OAuth b ->
      String.equal a.access_token b.access_token
      && Option.equal String.equal a.refresh_token b.refresh_token
      && Option.equal Int64.equal a.expires_at b.expires_at
      && Option.equal String.equal a.account_id b.account_id
  | (Api_key _ | Bearer _ | OAuth _), _ -> false

let secret_view_value = testable ~pp:pp_secret_view ~equal:equal_secret_view ()

let secret_view secret =
  Secret.expose secret
    ~api_key:(fun ~key -> Api_key key)
    ~bearer:(fun ~token -> Bearer token)
    ~oauth:(fun ~access_token ~refresh_token ~expires_at ~account_id ->
      OAuth { access_token; refresh_token; expires_at; account_id })

let openai = Llm_provider.make "openai"
let anthropic = Llm_provider.make "anthropic"
let responses = Llm_model.Api.make "responses"
let messages = Llm_model.Api.make "messages"

let llm ?(provider = openai) ?(api = responses) id =
  Llm_model.make ~provider ~api ~id

let gpt_5 = llm "gpt-5"
let gpt_5_mini = llm "gpt-5-mini"
let option_map f = function None -> None | Some value -> Some (f value)
let modality_strings modalities = List.map Modality.to_string modalities
let capability_strings capabilities = List.map Capability.to_string capabilities

let assert_price_input msg expected price =
  equal (option float_value) ~msg expected price.Model.input_per_million

let env_contracts () =
  let api_key = Env.api_key "OPENAI_API_KEY" in
  let bearer = Env.bearer "OPENAI_BEARER" in
  let oauth = Env.oauth_access_token "OPENAI_ACCESS_TOKEN" in
  equal string ~msg:"env name" "OPENAI_API_KEY" (Env.name api_key);
  equal kind_value ~msg:"api key kind" Account.Secret.Kind.Api_key
    (Env.kind api_key);
  equal secret_view_value ~msg:"api key decode" (Api_key "sk-test")
    (secret_view (Result.get_ok (Env.secret api_key "sk-test")));
  equal secret_view_value ~msg:"bearer decode" (Bearer "session-token")
    (secret_view (Result.get_ok (Env.secret bearer "session-token")));
  equal secret_view_value ~msg:"OAuth access-token decode"
    (OAuth
       {
         access_token = "access-token";
         refresh_token = None;
         expires_at = None;
         account_id = None;
       })
    (secret_view (Result.get_ok (Env.secret oauth "access-token")));
  expect_invalid_arg "env name cannot be empty" (fun () -> Env.api_key "");
  expect_invalid_arg "env name cannot start with digit" (fun () ->
      Env.api_key "1TOKEN");
  expect_invalid_arg "env name rejects hyphen" (fun () ->
      Env.api_key "OPENAI-KEY");
  begin match Env.secret api_key "" with
  | Error (Env.Error.Invalid_secret { name = "OPENAI_API_KEY"; _ }) -> ()
  | Error error -> failf "unexpected env decode error: %a" Env.Error.pp error
  | Ok secret ->
      ignore secret;
      failf "expected env decode error"
  end;
  assert_lacks "env formatter excludes secret" "sk-test"
    (Format.asprintf "%a" Env.pp api_key)

let login_contracts () =
  let api_key = Login.api_key () in
  equal string ~msg:"API-key method id" "api-key" (Login.id api_key);
  equal string ~msg:"API-key label" "API key" (Login.label api_key);
  begin match Login.protocol api_key with
  | Login.Protocol.Api_key -> ()
  | Login.Protocol.OAuth2_device_code _
  | Login.Protocol.OAuth2_authorization_code _
  | Login.Protocol.Provider_device_code _ | Login.Protocol.External _ ->
      failf "expected API-key protocol"
  end;
  let external_ =
    Login.make ~id:"external" ~label:"External"
      (Login.Protocol.External { instructions = Some "configure externally" })
  in
  equal string ~msg:"external method id" "external" (Login.id external_);
  begin match Login.protocol external_ with
  | Login.Protocol.External { instructions = Some instructions } ->
      equal string ~msg:"external instructions" "configure externally"
        instructions
  | Login.Protocol.Api_key | Login.Protocol.OAuth2_device_code _
  | Login.Protocol.OAuth2_authorization_code _
  | Login.Protocol.Provider_device_code _
  | Login.Protocol.External { instructions = None } ->
      failf "expected external protocol with instructions"
  end;
  let device =
    Login.make ~id:"device-code" ~label:"Device"
      (Login.Protocol.Provider_device_code { provider_flow = "openai_chatgpt" })
  in
  begin match Login.protocol device with
  | Login.Protocol.Provider_device_code { provider_flow } ->
      equal string ~msg:"provider device flow names its interpreter"
        "openai_chatgpt" provider_flow
  | Login.Protocol.Api_key | Login.Protocol.OAuth2_device_code _
  | Login.Protocol.OAuth2_authorization_code _ | Login.Protocol.External _ ->
      failf "expected provider device-code protocol"
  end;
  let client = Oauth2.Client.make ~id:"client-id" () in
  let device_endpoint = Uri.of_string "https://auth.example/device" in
  let token_endpoint = Uri.of_string "https://auth.example/token" in
  let oauth_device =
    Login.oauth2_device_code ~id:"oauth-device" ~label:"OAuth device" ~client
      ~device_endpoint ~token_endpoint ~scope:[ "openid"; "profile" ]
      ~extra:[ ("audience", "spice") ]
      ()
  in
  begin match Login.protocol oauth_device with
  | Login.Protocol.OAuth2_device_code spec ->
      equal string ~msg:"OAuth device endpoint" "https://auth.example/device"
        (Uri.to_string spec.Login.Protocol.device_endpoint);
      equal string ~msg:"OAuth device token endpoint"
        "https://auth.example/token"
        (Uri.to_string spec.Login.Protocol.device_token_endpoint);
      equal (list string) ~msg:"OAuth device scopes" [ "openid"; "profile" ]
        spec.Login.Protocol.device_scope;
      equal
        (list (pair string string))
        ~msg:"OAuth device extras"
        [ ("audience", "spice") ]
        spec.Login.Protocol.device_extra
  | Login.Protocol.Api_key | Login.Protocol.OAuth2_authorization_code _
  | Login.Protocol.Provider_device_code _ | Login.Protocol.External _ ->
      failf "expected OAuth device-code protocol"
  end;
  let authorization_endpoint = Uri.of_string "https://auth.example/authorize" in
  let redirect_uri = Uri.of_string "http://localhost:1455/auth/callback" in
  let oauth_browser =
    Login.oauth2_authorization_code ~id:"oauth-browser" ~label:"OAuth browser"
      ~client ~authorization_endpoint ~token_endpoint ~redirect_uri ~pkce:false
      ~scope:[ "email"; "offline_access" ]
      ~extra:[ ("prompt", "consent") ]
      ()
  in
  begin match Login.protocol oauth_browser with
  | Login.Protocol.OAuth2_authorization_code spec ->
      equal string ~msg:"OAuth browser authorization endpoint"
        "https://auth.example/authorize"
        (Uri.to_string spec.Login.Protocol.authorization_endpoint);
      equal string ~msg:"OAuth browser token endpoint"
        "https://auth.example/token"
        (Uri.to_string spec.Login.Protocol.authorization_token_endpoint);
      equal (option string) ~msg:"OAuth browser redirect"
        (Some "http://localhost:1455/auth/callback")
        (Option.map
           (fun uri -> Uri.to_string uri)
           spec.Login.Protocol.redirect_uri);
      equal (list string) ~msg:"OAuth browser scopes"
        [ "email"; "offline_access" ]
        spec.Login.Protocol.authorization_scope;
      equal
        (list (pair string string))
        ~msg:"OAuth browser extras"
        [ ("prompt", "consent") ]
        spec.Login.Protocol.authorization_extra;
      is_false ~msg:"OAuth browser PKCE can be disabled"
        spec.Login.Protocol.pkce
  | Login.Protocol.Api_key | Login.Protocol.OAuth2_device_code _
  | Login.Protocol.Provider_device_code _ | Login.Protocol.External _ ->
      failf "expected OAuth authorization-code protocol"
  end;
  expect_invalid_arg "login id cannot be empty" (fun () ->
      Login.make ~id:"" ~label:"Empty" Login.Protocol.Api_key);
  expect_invalid_arg "login id rejects uppercase" (fun () ->
      Login.make ~id:"Browser" ~label:"Browser" Login.Protocol.Api_key);
  expect_invalid_arg "login label cannot be empty" (fun () ->
      Login.make ~id:"browser" ~label:"" Login.Protocol.Api_key);
  expect_invalid_arg "duplicate env declarations rejected" (fun () ->
      Auth.make
        ~env:[ Env.api_key "OPENAI_API_KEY"; Env.bearer "OPENAI_API_KEY" ]
        ());
  expect_invalid_arg "duplicate login methods rejected" (fun () ->
      Auth.make
        ~login:[ Login.api_key (); Login.api_key ~label:"Other API key" () ]
        ());
  is_true ~msg:"declaring methods defaults to required"
    (Auth.required (Auth.make ~login:[ Login.api_key () ] ()));
  is_true ~msg:"no methods defaults to not required"
    (not (Auth.required (Auth.make ())));
  is_true ~msg:"optional auth keeps its methods"
    (not
       (Auth.required
          (Auth.make ~required:false ~login:[ Login.api_key () ] ())));
  expect_invalid_arg "required auth must declare a method" (fun () ->
      Auth.make ~required:true ())

let modality_contracts () =
  let depth = Modality.extension "depth_map" in
  equal (option modality_value) ~msg:"built-in text parses" (Some Modality.text)
    (Modality.of_string "text");
  equal (option modality_value) ~msg:"extension parses" (Some depth)
    (Modality.of_string "depth_map");
  equal string ~msg:"extension spelling" "depth_map" (Modality.to_string depth);
  equal (list string) ~msg:"modalities sort by spelling"
    [ "depth_map"; "text"; "video" ]
    (List.sort Modality.compare [ Modality.video; Modality.text; depth ]
    |> modality_strings);
  equal (option modality_value) ~msg:"invalid modality is None" None
    (Modality.of_string "bad tag");
  expect_invalid_arg "modality extension rejects reserved name" (fun () ->
      Modality.extension "text");
  expect_invalid_arg "modality extension rejects uppercase" (fun () ->
      Modality.extension "Text")

let capability_contracts () =
  let computer_use = Capability.extension "computer_use" in
  equal (option capability_value) ~msg:"built-in json_schema parses"
    (Some Capability.json_schema)
    (Capability.of_string "json_schema");
  equal (option capability_value) ~msg:"extension parses" (Some computer_use)
    (Capability.of_string "computer_use");
  equal string ~msg:"extension spelling" "computer_use"
    (Capability.to_string computer_use);
  equal (list string) ~msg:"capabilities sort by spelling"
    [ "computer_use"; "json_schema"; "tools" ]
    (List.sort Capability.compare
       [ Capability.tools; computer_use; Capability.json_schema ]
    |> capability_strings);
  equal (option capability_value) ~msg:"invalid capability is None" None
    (Capability.of_string "bad tag");
  expect_invalid_arg "capability extension rejects reserved name" (fun () ->
      Capability.extension "tools");
  expect_invalid_arg "capability extension rejects leading digit" (fun () ->
      Capability.extension "2tools")

let date_contracts () =
  let leap = Date.make ~year:2024 ~month:2 ~day:29 in
  equal string ~msg:"date formats as ISO calendar date" "2024-02-29"
    (Date.to_string leap);
  equal (option date_value) ~msg:"date parses" (Some leap)
    (Date.of_string "2024-02-29");
  equal (option date_value) ~msg:"invalid leap day is None" None
    (Date.of_string "2023-02-29");
  equal (option date_value) ~msg:"non-padded date is None" None
    (Date.of_string "2024-2-29");
  equal (option date_value) ~msg:"year zero is None" None
    (Date.of_string "0000-01-01");
  expect_invalid_arg "constructor rejects invalid date" (fun () ->
      Date.make ~year:2023 ~month:2 ~day:29);
  expect_invalid_arg "constructor rejects month 13" (fun () ->
      Date.make ~year:2024 ~month:13 ~day:1);
  is_true ~msg:"dates compare chronologically"
    (Date.compare leap (Date.make ~year:2025 ~month:1 ~day:1) < 0)

let pricing_contracts () =
  let default = Model.price ~input_per_million:1. ~output_per_million:2. () in
  let over_100 = Model.price ~input_per_million:3. () in
  let over_1000 = Model.price ~input_per_million:5. () in
  let pricing =
    Model.make_pricing default
      ~context_over:[ (1000, over_1000); (100, over_100) ]
  in
  equal (option float_value) ~msg:"price input field" (Some 1.)
    default.Model.input_per_million;
  equal (option float_value) ~msg:"price output field" (Some 2.)
    default.Model.output_per_million;
  equal (list int) ~msg:"context thresholds are sorted deterministically"
    [ 100; 1000 ]
    (pricing.Model.context_over |> List.map fst);
  assert_price_input "default price without context" (Some 1.)
    (Model.price_for pricing);
  assert_price_input "threshold is strictly greater than" (Some 1.)
    (Model.price_for ~context_tokens:100 pricing);
  assert_price_input "matching lower threshold" (Some 3.)
    (Model.price_for ~context_tokens:101 pricing);
  assert_price_input "greatest matching threshold wins" (Some 5.)
    (Model.price_for ~context_tokens:1001 pricing);
  expect_invalid_arg "negative price rejected" (fun () ->
      Model.price ~input_per_million:(-0.01) ());
  expect_invalid_arg "NaN price rejected" (fun () ->
      Model.price ~input_per_million:Float.nan ());
  expect_invalid_arg "infinite price rejected" (fun () ->
      Model.price ~input_per_million:Float.infinity ());
  expect_invalid_arg "negative context threshold rejected" (fun () ->
      Model.make_pricing default ~context_over:[ (-1, over_100) ]);
  expect_invalid_arg "duplicate context thresholds rejected" (fun () ->
      Model.make_pricing default
        ~context_over:[ (100, over_100); (100, over_1000) ]);
  expect_invalid_arg "negative context rejected" (fun () ->
      Model.price_for ~context_tokens:(-1) pricing)

let cost_contracts () =
  equal (option float_value) ~msg:"a model without pricing has no cost" None
    (Model.cost (Model.make gpt_5 ()) Usage.zero);
  let price =
    Model.price ~input_per_million:1. ~cached_input_per_million:0.5
      ~output_per_million:2. ~cache_write_5m_per_million:1.25 ()
  in
  let model = Model.make gpt_5 ~pricing:(Model.make_pricing price) () in
  equal (option float_value) ~msg:"zero usage costs nothing" (Some 0.)
    (Model.cost model Usage.zero);
  let usage =
    Usage.make ~input:1_000_000 ~output:1_000_000 ~reasoning:1_000_000
      ~cache_read:1_000_000 ~cache_write:1_000_000 ()
  in
  (* input 1.0 + cache_read 0.5 + cache_write 1.25 + output 2.0 +
     reasoning 2.0 (billed at the output rate). *)
  equal (option float_value) ~msg:"each lane bills against its own rate"
    (Some 6.75) (Model.cost model usage);
  let input_only =
    Model.make gpt_5
      ~pricing:(Model.make_pricing (Model.price ~input_per_million:1. ()))
      ()
  in
  equal (option float_value) ~msg:"a spent lane with an unknown rate is unknown"
    None
    (Model.cost input_only (Usage.make ~input:1_000_000 ~output:1_000_000 ()));
  equal (option float_value)
    ~msg:"an unknown rate on an unspent lane does not force unknown" (Some 1.)
    (Model.cost input_only (Usage.make ~input:1_000_000 ~output:0 ()));
  let tiered =
    Model.make gpt_5
      ~pricing:
        (Model.make_pricing
           (Model.price ~input_per_million:1. ())
           ~context_over:[ (2_000_000, Model.price ~input_per_million:10. ()) ])
      ()
  in
  (* input_total (input + cache lanes) is 3M, over the 2M threshold, so the
     higher tier's rate applies: 3M / 1e6 * 10. *)
  equal (option float_value)
    ~msg:"the input side selects the context price tier" (Some 30.)
    (Model.cost tiered (Usage.make ~input:3_000_000 ~output:0 ()));
  let large_usage = Usage.make ~input:max_int ~cache_read:1 ~output:0 () in
  is_true ~msg:"overflowing input total does not prevent cost reporting"
    (Option.is_some (Model.cost model large_usage))

let model_contracts () =
  let released_on = Date.make ~year:2026 ~month:1 ~day:15 in
  let default = Model.make gpt_5 () in
  equal llm_model_value ~msg:"model llm accessor" gpt_5 (Model.llm default);
  equal provider_value ~msg:"model provider accessor" openai
    (Model.provider default);
  equal string ~msg:"model api accessor" "responses"
    (Model.api default |> Spice_llm.Model.Api.id);
  equal string ~msg:"model id accessor" "gpt-5" (Model.id default);
  equal string ~msg:"model selector" "openai/gpt-5" (Model.selector default);
  equal (option string) ~msg:"default display name" None
    (Model.display_name default);
  equal (list string) ~msg:"default input modality is text" [ "text" ]
    (Model.input_modalities default |> modality_strings);
  equal (list string) ~msg:"default output modality is text" [ "text" ]
    (Model.output_modalities default |> modality_strings);
  begin match Model.status default with
  | Model.Stable -> ()
  | Model.Preview | Model.Deprecated | Model.Unavailable _ ->
      failf "expected stable status"
  end;
  is_true ~msg:"stable model is visible" (Model.visible default);
  is_true ~msg:"stable model is selectable" (Model.selectable default);
  let deprecated = Model.make gpt_5 ~status:Model.Deprecated () in
  is_true ~msg:"deprecated model is visible" (Model.visible deprecated);
  is_false ~msg:"deprecated model is not selectable"
    (Model.selectable deprecated);
  let unavailable = Model.make gpt_5 ~status:(Model.Unavailable "retired") () in
  is_false ~msg:"unavailable model is hidden" (Model.visible unavailable);
  is_false ~msg:"unavailable model is not selectable"
    (Model.selectable unavailable);
  let rich =
    Model.make gpt_5 ~display_name:"GPT-5" ~family:"gpt-5" ~released_on
      ~context_window:400_000 ~max_output_tokens:128_000
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:
        [
          Options.Reasoning_effort.High;
          Options.Reasoning_effort.Medium;
          Options.Reasoning_effort.Low;
        ]
      ~input_modalities:[ Modality.image; Modality.text ]
      ~output_modalities:[ Modality.text ]
      ~capabilities:
        [ Capability.tools; Capability.json_schema; Capability.reasoning ]
      ~status:Model.Preview ()
  in
  equal (option string) ~msg:"display name" (Some "GPT-5")
    (Model.display_name rich);
  equal (option string) ~msg:"family" (Some "gpt-5") (Model.family rich);
  equal (option date_value) ~msg:"release date" (Some released_on)
    (Model.released_on rich);
  equal (option int) ~msg:"context window" (Some 400_000)
    (Model.context_window rich);
  equal (option int) ~msg:"max output tokens" (Some 128_000)
    (Model.max_output_tokens rich);
  equal (option string) ~msg:"default reasoning" (Some "medium")
    (Model.default_reasoning rich
    |> option_map (function
      | Options.Reasoning_effort.Medium -> "medium"
      | Options.Reasoning_effort.Disabled | Options.Reasoning_effort.Minimal
      | Options.Reasoning_effort.Low | Options.Reasoning_effort.High
      | Options.Reasoning_effort.Extra_high | Options.Reasoning_effort.Max ->
          "other"));
  equal (list string) ~msg:"input modalities are sorted" [ "image"; "text" ]
    (Model.input_modalities rich |> modality_strings);
  is_true ~msg:"input modality membership"
    (Model.has_input_modality Modality.image rich);
  is_false ~msg:"missing output modality membership"
    (Model.has_output_modality Modality.image rich);
  equal (list string) ~msg:"capabilities are sorted"
    [ "json_schema"; "reasoning"; "tools" ]
    (Model.capabilities rich |> capability_strings);
  is_true ~msg:"capability membership"
    (Model.has_capability Capability.tools rich);
  expect_invalid_arg "display_name cannot be empty" (fun () ->
      Model.make gpt_5 ~display_name:"" ());
  expect_invalid_arg "family cannot be empty" (fun () ->
      Model.make gpt_5 ~family:"" ());
  expect_invalid_arg "context_window must be positive" (fun () ->
      Model.make gpt_5 ~context_window:0 ());
  expect_invalid_arg "max_output_tokens must be positive" (fun () ->
      Model.make gpt_5 ~max_output_tokens:(-1) ());
  expect_invalid_arg "duplicate input modalities rejected" (fun () ->
      Model.make gpt_5 ~input_modalities:[ Modality.text; Modality.text ] ());
  expect_invalid_arg "duplicate capabilities rejected" (fun () ->
      Model.make gpt_5 ~capabilities:[ Capability.tools; Capability.tools ] ());
  expect_invalid_arg "duplicate reasoning efforts rejected" (fun () ->
      Model.make gpt_5
        ~supported_reasoning:
          [ Options.Reasoning_effort.Low; Options.Reasoning_effort.Low ]
        ());
  expect_invalid_arg "default reasoning must be supported" (fun () ->
      Model.make gpt_5 ~default_reasoning:Options.Reasoning_effort.Medium
        ~supported_reasoning:[ Options.Reasoning_effort.Low ]
        ())

let provider_contracts () =
  let model = Model.make gpt_5 () in
  let mini = Model.make gpt_5_mini () in
  let auth =
    Auth.make
      ~env:[ Env.api_key "OPENAI_API_KEY"; Env.bearer "OPENAI_TOKEN" ]
      ~login:[ Login.api_key () ]
      ()
  in
  let provider =
    Provider.make openai ~display_name:"OpenAI" ~auth ~default_model:gpt_5
      [ mini; model ]
  in
  equal provider_value ~msg:"provider id" openai (Provider.id provider);
  equal (option string) ~msg:"provider display name" (Some "OpenAI")
    (Provider.display_name provider);
  equal (list string) ~msg:"env declarations keep declaration order"
    [ "OPENAI_API_KEY"; "OPENAI_TOKEN" ]
    (Provider.auth provider |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"login declarations keep declaration order"
    [ "api-key" ]
    (Provider.auth provider |> Auth.logins |> List.map Login.id);
  equal (list string) ~msg:"models keep declaration order"
    [ "gpt-5-mini"; "gpt-5" ]
    (Provider.models provider
    |> List.map (fun model -> Llm_model.id (Model.llm model)));
  equal (option llm_model_value) ~msg:"default model lookup" (Some gpt_5)
    (Provider.default_model provider |> option_map Model.llm);
  equal (option llm_model_value) ~msg:"declared model lookup" (Some gpt_5_mini)
    (Provider.model provider gpt_5_mini |> option_map Model.llm);
  equal (option llm_model_value) ~msg:"missing model lookup" None
    (Provider.model provider (llm "gpt-4") |> option_map Model.llm);
  let dynamic =
    Provider.make openai
      ~dynamic_model:(fun id ->
        if String.ends_with ~suffix:".gguf" id then
          Some (Model.make (llm id) ())
        else None)
      [ model ]
  in
  equal (option llm_model_value) ~msg:"dynamic model lookup"
    (Some (llm "weights.gguf"))
    (Provider.dynamic_model dynamic "weights.gguf" |> option_map Model.llm);
  equal (option llm_model_value) ~msg:"dynamic model miss" None
    (Provider.dynamic_model dynamic "weights.bin" |> option_map Model.llm);
  expect_invalid_arg "dynamic model rejects declared ids" (fun () ->
      Provider.dynamic_model dynamic "gpt-5" |> ignore);
  let bad_dynamic =
    Provider.make openai
      ~dynamic_model:(fun _ ->
        Some (Model.make (llm ~provider:anthropic ~api:messages "claude") ()))
      []
  in
  expect_invalid_arg "dynamic model provider must match" (fun () ->
      Provider.dynamic_model bad_dynamic "claude" |> ignore);
  expect_invalid_arg "display_name cannot be empty" (fun () ->
      Provider.make openai ~display_name:"" [ model ]);
  expect_invalid_arg "foreign model rejected" (fun () ->
      Provider.make openai
        [ Model.make (llm ~provider:anthropic ~api:messages "claude") () ]);
  expect_invalid_arg "duplicate models rejected" (fun () ->
      Provider.make openai [ model; Model.make gpt_5 () ]);
  expect_invalid_arg "duplicate model ids rejected" (fun () ->
      Provider.make openai [ model; Model.make (llm ~api:messages "gpt-5") () ]);
  expect_invalid_arg "undeclared default rejected" (fun () ->
      Provider.make openai ~default_model:gpt_5_mini [ model ]);
  expect_invalid_arg "unselectable default rejected" (fun () ->
      let hidden = Model.make gpt_5 ~status:(Model.Unavailable "retired") () in
      Provider.make openai ~default_model:gpt_5 [ hidden ])

let selector_of msg raw =
  match Selector.of_string raw with
  | Ok selector -> selector
  | Error error ->
      failf "%s: unexpected selector error: %s" msg
        (Selector.Error.message error)

let selector_error msg raw =
  match Selector.of_string raw with
  | Ok _ -> failf "%s: expected selector error" msg
  | Error error -> Selector.Error.message error

let selector_contracts () =
  let selector = selector_of "basic" "openai/gpt-5" in
  equal provider_value ~msg:"selector provider" openai
    (Selector.provider selector);
  equal string ~msg:"selector model id" "gpt-5" (Selector.id selector);
  (* split is on the first '/', so the model id may itself contain slashes *)
  equal string ~msg:"model id keeps later slashes" "family/gpt-5"
    (Selector.id (selector_of "nested" "openai/family/gpt-5"));
  let trimmed = selector_of "trim" "  openai/gpt-5  " in
  equal provider_value ~msg:"outer whitespace is trimmed" openai
    (Selector.provider trimmed);
  equal string ~msg:"trimmed selector keeps model id" "gpt-5"
    (Selector.id trimmed);
  equal string ~msg:"empty input diagnostic" "model selector must not be empty"
    (selector_error "empty" "   ");
  equal string ~msg:"missing separator diagnostic"
    "model selector must be in the form provider/model"
    (selector_error "missing slash" "openai");
  equal string ~msg:"empty provider diagnostic"
    "model selector provider must not be empty"
    (selector_error "empty provider" "/gpt-5");
  equal string ~msg:"empty model diagnostic"
    "model selector model must not be empty"
    (selector_error "empty model" "openai/");
  is_true ~msg:"invalid provider names the offending segment"
    (String.includes ~affix:"is invalid"
       (selector_error "invalid provider" "OpenAI/gpt-5"))

(* A valid provider namespace: a lowercase letter, then lowercase letters,
   digits, or '-' (mirrors Spice_llm.Provider.make). *)
let provider_gen =
  let open Gen in
  let tail_char =
    oneofl
      (List.init 26 (fun i -> Char.chr (Char.code 'a' + i))
      @ List.init 10 (fun i -> Char.chr (Char.code '0' + i))
      @ [ '-' ])
  in
  let+ head = char_range 'a' 'z'
  and+ tail = string_size (int_range 0 7) tail_char in
  String.make 1 head ^ tail

(* A model id is any non-empty string. Restrict to non-whitespace characters so
   the round-trip is exact: [of_string] trims the whole string, which would drop
   trailing whitespace from a naive concatenation. *)
let model_gen =
  let model_char = Gen.oneofl [ 'a'; 'z'; '0'; '9'; '-'; '.'; '_'; '/'; 'A' ] in
  Gen.string_size (Gen.int_range 1 10) model_char

let selector_pair =
  testable
    ~pp:(fun ppf (p, m) -> Format.fprintf ppf "%S / %S" p m)
    ~gen:(Gen.pair provider_gen model_gen)
    ()

let selector_roundtrips =
  prop' "of_string parses back any valid provider/model" selector_pair
    (fun (provider, model) ->
      let raw = provider ^ "/" ^ model in
      match Selector.of_string raw with
      | Ok selector ->
          equal string ~msg:"provider round-trips" provider
            (Llm_provider.id (Selector.provider selector));
          equal string ~msg:"model round-trips" model (Selector.id selector)
      | Error error ->
          failf "valid selector %S rejected: %s" raw
            (Selector.Error.message error))

let catalog_contracts () =
  let hidden =
    Model.make (llm "gpt-4") ~status:(Model.Unavailable "retired") ()
  in
  let provider =
    Provider.make openai
      ~dynamic_model:(fun id ->
        if String.ends_with ~suffix:".gguf" id then
          Some (Model.make (llm id) ())
        else None)
      [ Model.make gpt_5_mini (); hidden; Model.make gpt_5 () ]
  in
  let claude = llm ~provider:anthropic ~api:messages "claude-3" in
  let anthropic_provider = Provider.make anthropic [ Model.make claude () ] in
  expect_error "duplicate provider" provider_value openai
    (Catalog.of_list [ provider; Provider.make openai [] ]);
  let catalog =
    Result.get_ok (Catalog.of_list [ provider; anthropic_provider ])
  in
  equal (list provider_value) ~msg:"catalog preserves provider order"
    [ openai; anthropic ]
    (Catalog.providers catalog |> List.map Provider.id);
  equal (option provider_value) ~msg:"catalog provider lookup" (Some openai)
    (Catalog.provider catalog openai |> option_map Provider.id);
  equal (option provider_value) ~msg:"catalog provider lookup misses" None
    (Catalog.provider catalog (Llm_provider.make "google")
    |> option_map Provider.id);
  equal (list string) ~msg:"catalog models hide unavailable by default"
    [ "gpt-5-mini"; "gpt-5"; "claude-3" ]
    (Catalog.models catalog |> List.map Model.id);
  equal (list string) ~msg:"catalog models include hidden when requested"
    [ "gpt-5-mini"; "gpt-4"; "gpt-5"; "claude-3" ]
    (Catalog.models ~include_hidden:true catalog |> List.map Model.id);
  equal
    (result (list string) catalog_error_value)
    ~msg:"catalog models_for"
    (Ok [ "gpt-5-mini"; "gpt-5" ])
    (Catalog.models_for catalog openai |> Result.map (List.map Model.id));
  equal
    (result (list string) catalog_error_value)
    ~msg:"catalog models_for unknown provider"
    (Error
       (Catalog.Lookup_error.Unknown_provider
          {
            provider = Llm_provider.make "google";
            known = [ "openai"; "anthropic" ];
          }))
    (Catalog.models_for catalog (Llm_provider.make "google")
    |> Result.map (List.map Model.id));
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog resolves selector string" (Ok gpt_5)
    (Catalog.resolve catalog " openai/gpt-5 " |> Result.map Model.llm);
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog resolves hidden selector"
    (Ok (llm "gpt-4"))
    (Catalog.resolve catalog "openai/gpt-4" |> Result.map Model.llm);
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog resolves dynamic selector"
    (Ok (llm "weights.gguf"))
    (Catalog.resolve catalog "openai/weights.gguf" |> Result.map Model.llm);
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog reports invalid selector"
    (Error
       (Catalog.Lookup_error.Invalid_selector
          {
            input = "openai";
            message = "model selector must be in the form provider/model";
            candidates =
              [
                "openai/gpt-5-mini";
                "openai/gpt-4";
                "openai/gpt-5";
                "anthropic/claude-3";
              ];
          }))
    (Catalog.resolve catalog "openai" |> Result.map Model.llm);
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog reports unknown provider"
    (Error
       (Catalog.Lookup_error.Unknown_provider
          {
            provider = Llm_provider.make "google";
            known = [ "openai"; "anthropic" ];
          }))
    (Catalog.resolve catalog "google/gemini" |> Result.map Model.llm);
  equal
    (result llm_model_value catalog_error_value)
    ~msg:"catalog reports unknown model"
    (Error
       (Catalog.Lookup_error.Unknown_model
          {
            provider = openai;
            model = "gpt-6";
            known = [ "gpt-5-mini"; "gpt-4"; "gpt-5" ];
          }))
    (Catalog.resolve catalog "openai/gpt-6" |> Result.map Model.llm)

let () =
  run "spice.provider"
    [
      test "env contracts" env_contracts;
      test "login contracts" login_contracts;
      test "modality contracts" modality_contracts;
      test "capability contracts" capability_contracts;
      test "date contracts" date_contracts;
      test "pricing contracts" pricing_contracts;
      test "cost contracts" cost_contracts;
      test "model contracts" model_contracts;
      test "provider contracts" provider_contracts;
      test "selector contracts" selector_contracts;
      selector_roundtrips;
      test "catalog contracts" catalog_contracts;
    ]
