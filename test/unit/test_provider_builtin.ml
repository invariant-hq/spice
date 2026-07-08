(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Builtin = Spice_provider_builtin
module Auth = Spice_provider.Auth
module Capability = Spice_provider.Model.Capability
module Catalog = Spice_provider.Catalog
module Env = Auth.Env
module Login = Auth.Login
module Llm_model = Spice_llm.Model
module Llm_provider = Spice_llm.Provider
module Model = Spice_provider.Model
module Modality = Spice_provider.Model.Modality
module Options = Spice_llm.Request.Options
module Provider = Spice_provider

let float_value = testable ~pp:Format.pp_print_float ~equal:Float.equal ()
let provider_id provider = provider |> Provider.id |> Llm_provider.id
let model_id model = model |> Model.llm |> Llm_model.id
let provider_auth provider = Provider.auth provider

let capability_strings model =
  model |> Model.capabilities |> List.map Capability.to_string

let input_modality_strings model =
  model |> Model.input_modalities |> List.map Modality.to_string

let lookup provider llm =
  match Provider.model provider llm with
  | Some model -> model
  | None -> failf "missing model %a" Llm_model.pp llm

let openai_contracts () =
  equal string ~msg:"provider id" "openai" (provider_id Builtin.openai);
  equal (list string) ~msg:"OpenAI env" [ "OPENAI_API_KEY" ]
    (Builtin.openai |> provider_auth |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"OpenAI login methods"
    [ "browser"; "device-code"; "api-key" ]
    (Builtin.openai |> provider_auth |> Auth.logins |> List.map Login.id);
  begin match
    Auth.login_by_id (Builtin.openai |> provider_auth) "device-code"
    |> Option.map Login.protocol
  with
  | Some
      (Login.Protocol.Provider_device_code { provider_flow = "openai_chatgpt" })
    ->
      ()
  | Some
      ( Login.Protocol.Api_key | Login.Protocol.OAuth2_device_code _
      | Login.Protocol.OAuth2_authorization_code _
      | Login.Protocol.Provider_device_code _ | Login.Protocol.External _ )
  | None ->
      failf "expected OpenAI ChatGPT device-code login"
  end;
  equal int ~msg:"OpenAI catalog is curated" 8
    (Builtin.openai |> Provider.models |> List.length);
  equal (option string) ~msg:"OpenAI default model" (Some "gpt-5.5")
    (Builtin.openai |> Provider.default_model |> Option.map model_id);
  let gpt_55 = lookup Builtin.openai (Spice_llm_openai.model "gpt-5.5") in
  equal (option string) ~msg:"display name" (Some "GPT-5.5")
    (Model.display_name gpt_55);
  equal (option string) ~msg:"family" (Some "gpt") (Model.family gpt_55);
  equal (option int) ~msg:"context window" (Some 1_050_000)
    (Model.context_window gpt_55);
  equal (list string) ~msg:"input modalities include PDF"
    [ "image"; "pdf"; "text" ]
    (input_modality_strings gpt_55);
  equal (list string) ~msg:"capabilities"
    [ "apply-patch"; "json_schema"; "reasoning"; "tools" ]
    (capability_strings gpt_55);
  is_true ~msg:"gpt-5.5 is an apply-patch coding model"
    (Model.has_capability (Capability.extension "apply-patch") gpt_55);
  let image = lookup Builtin.openai (Spice_llm_openai.model "gpt-image-1.5") in
  is_true ~msg:"gpt-image is not an apply-patch coding model"
    (not (Model.has_capability (Capability.extension "apply-patch") image));
  equal (list string) ~msg:"OpenAI reasoning efforts"
    [ "none"; "low"; "medium"; "high"; "xhigh" ]
    (Model.supported_reasoning gpt_55
    |> List.map Options.Reasoning_effort.to_string);
  begin match Model.pricing gpt_55 with
  | None -> failf "expected gpt-5.5 pricing metadata"
  | Some pricing ->
      equal (option float_value) ~msg:"default input cost" (Some 5.)
        pricing.Model.default.Model.input_per_million;
      let tiered = Model.price_for ~context_tokens:300_000 pricing in
      equal (option float_value) ~msg:"tiered input cost" (Some 10.)
        tiered.Model.input_per_million
  end;
  let chat =
    lookup Builtin.openai (Spice_llm_openai.model "gpt-5-chat-latest")
  in
  begin match Model.status chat with
  | Model.Unavailable reason ->
      is_true ~msg:"chat alias has diagnostic reason" (String.length reason > 0)
  | Model.Stable | Model.Preview | Model.Deprecated ->
      failf "expected unavailable chat alias"
  end

let anthropic_contracts () =
  equal string ~msg:"provider id" "anthropic" (provider_id Builtin.anthropic);
  equal (list string) ~msg:"Anthropic env" [ "ANTHROPIC_API_KEY" ]
    (Builtin.anthropic |> provider_auth |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"Anthropic login methods" [ "api-key" ]
    (Builtin.anthropic |> provider_auth |> Auth.logins |> List.map Login.id);
  equal int ~msg:"Anthropic catalog is curated" 5
    (Builtin.anthropic |> Provider.models |> List.length);
  equal (option string) ~msg:"Anthropic default model"
    (Some "claude-sonnet-4-6")
    (Builtin.anthropic |> Provider.default_model |> Option.map model_id);
  let opus_48 =
    lookup Builtin.anthropic (Spice_llm_anthropic.model "claude-opus-4-8")
  in
  equal (option string) ~msg:"opus 4.8 display name" (Some "Claude Opus 4.8")
    (Model.display_name opus_48);
  let opus =
    lookup Builtin.anthropic (Spice_llm_anthropic.model "claude-opus-4-7")
  in
  equal (option string) ~msg:"display name" (Some "Claude Opus 4.7")
    (Model.display_name opus);
  equal (option int) ~msg:"context window" (Some 1_000_000)
    (Model.context_window opus);
  equal (list string) ~msg:"input modalities" [ "image"; "pdf"; "text" ]
    (input_modality_strings opus);
  equal (list string) ~msg:"capabilities" [ "reasoning"; "tools" ]
    (capability_strings opus);
  equal (list string) ~msg:"adaptive reasoning efforts"
    [ "low"; "medium"; "high"; "xhigh"; "max" ]
    (Model.supported_reasoning opus
    |> List.map Options.Reasoning_effort.to_string);
  let haiku =
    lookup Builtin.anthropic (Spice_llm_anthropic.model "claude-haiku-4-5")
  in
  equal (list string) ~msg:"Haiku has no effort presets" []
    (Model.supported_reasoning haiku
    |> List.map Options.Reasoning_effort.to_string);
  begin match Model.pricing opus with
  | None -> failf "expected claude-opus-4-7 pricing metadata"
  | Some pricing ->
      equal (option float_value) ~msg:"cache write maps to 5m price" (Some 6.25)
        pricing.Model.default.Model.cache_write_5m_per_million
  end

let google_contracts () =
  equal string ~msg:"provider id" "google" (provider_id Builtin.google);
  equal (list string) ~msg:"Google env"
    [ "GOOGLE_GENERATIVE_AI_API_KEY" ]
    (Builtin.google |> provider_auth |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"Google login methods" [ "api-key" ]
    (Builtin.google |> provider_auth |> Auth.logins |> List.map Login.id);
  equal int ~msg:"Google catalog is curated" 4
    (Builtin.google |> Provider.models |> List.length);
  equal (option string) ~msg:"Google default model"
    (Some "gemini-3-flash-preview")
    (Builtin.google |> Provider.default_model |> Option.map model_id);
  let flash =
    lookup Builtin.google (Spice_llm_google.model "gemini-3-flash-preview")
  in
  equal (option string) ~msg:"display name" (Some "Gemini 3 Flash Preview")
    (Model.display_name flash);
  equal (option int) ~msg:"context window" (Some 1_048_576)
    (Model.context_window flash);
  equal (list string) ~msg:"input modalities"
    [ "audio"; "image"; "pdf"; "text"; "video" ]
    (input_modality_strings flash);
  equal (list string) ~msg:"capabilities" [ "reasoning"; "tools" ]
    (capability_strings flash);
  equal (list string) ~msg:"Google reasoning efforts"
    [ "minimal"; "low"; "medium"; "high" ]
    (Model.supported_reasoning flash
    |> List.map Options.Reasoning_effort.to_string)

let deepseek_contracts () =
  equal string ~msg:"provider id" "deepseek" (provider_id Builtin.deepseek);
  equal (list string) ~msg:"DeepSeek env" []
    (Builtin.deepseek |> provider_auth |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"DeepSeek login methods" []
    (Builtin.deepseek |> provider_auth |> Auth.logins |> List.map Login.id);
  equal int ~msg:"DeepSeek catalog is curated" 4
    (Builtin.deepseek |> Provider.models |> List.length);
  equal (option string) ~msg:"DeepSeek default model" (Some "q2-q4-imatrix")
    (Builtin.deepseek |> Provider.default_model |> Option.map model_id);
  let q2q4 =
    lookup Builtin.deepseek (Spice_llm_deepseek.model "q2-q4-imatrix")
  in
  equal (option string) ~msg:"display name" (Some "DeepSeek V4 Flash q2/q4")
    (Model.display_name q2q4);
  equal (option int) ~msg:"context window" (Some 4096)
    (Model.context_window q2q4);
  equal (list string) ~msg:"input modalities" [ "text" ]
    (input_modality_strings q2q4);
  equal (list string) ~msg:"capabilities" [ "reasoning"; "tools" ]
    (capability_strings q2q4);
  equal (list string) ~msg:"DeepSeek reasoning efforts"
    [ "none"; "high"; "max" ]
    (Model.supported_reasoning q2q4
    |> List.map Options.Reasoning_effort.to_string)

let local_contracts () =
  equal string ~msg:"provider id" "local" (provider_id Builtin.local);
  equal (list string) ~msg:"Local env" []
    (Builtin.local |> provider_auth |> Auth.env |> List.map Env.name);
  equal (list string) ~msg:"Local login methods" []
    (Builtin.local |> provider_auth |> Auth.logins |> List.map Login.id);
  equal int ~msg:"Local catalog matches the manifest"
    (List.length Spice_llm_local.Manifest.all)
    (Builtin.local |> Provider.models |> List.length);
  equal (option string) ~msg:"Local default model" (Some "qwen3-coder-30b")
    (Builtin.local |> Provider.default_model |> Option.map model_id);
  let qwen = lookup Builtin.local (Spice_llm_local.model "qwen3-coder-30b") in
  equal (option string) ~msg:"display name" (Some "Qwen3 Coder 30B (Q4_K_M)")
    (Model.display_name qwen);
  equal (option int) ~msg:"context window" (Some 262_144)
    (Model.context_window qwen);
  equal (list string) ~msg:"coder capabilities" [ "json_schema"; "tools" ]
    (capability_strings qwen);
  let gpt_oss = lookup Builtin.local (Spice_llm_local.model "gpt-oss-20b") in
  equal (list string) ~msg:"reasoning capabilities"
    [ "json_schema"; "reasoning"; "tools" ]
    (capability_strings gpt_oss);
  is_true ~msg:"gpt-oss-20b is not an apply-patch coding model"
    (not (Model.has_capability (Capability.extension "apply-patch") gpt_oss));
  equal (list string) ~msg:"Local reasoning efforts"
    [ "none"; "low"; "medium"; "high" ]
    (Model.supported_reasoning gpt_oss
    |> List.map Options.Reasoning_effort.to_string)

let ollama_contracts () =
  equal string ~msg:"provider id" "ollama" (provider_id Builtin.ollama);
  equal (list string) ~msg:"Ollama env" [ "OLLAMA_API_KEY" ]
    (Builtin.ollama |> provider_auth |> Auth.env |> List.map Env.name);
  is_true ~msg:"Ollama auth is optional"
    (not (Auth.required (provider_auth Builtin.ollama)));
  equal (list string) ~msg:"Ollama logins" [ "api-key" ]
    (Builtin.ollama |> provider_auth |> Auth.logins |> List.map Auth.Login.id);
  equal int ~msg:"Ollama declares no static models" 0
    (Builtin.ollama |> Provider.models |> List.length);
  is_true ~msg:"Ollama has no default model"
    (Option.is_none (Provider.default_model Builtin.ollama));
  (match Provider.dynamic_model Builtin.ollama "qwen3-coder:30b" with
  | Some model ->
      equal string ~msg:"dynamic id is preserved" "qwen3-coder:30b"
        (model_id model);
      equal (list string) ~msg:"dynamic capabilities" [ "json_schema"; "tools" ]
        (capability_strings model)
  | None -> failf "expected a dynamic Ollama model");
  match Provider.dynamic_model Builtin.local "qwen3-coder-30" with
  | Some _ -> failf "local dynamic ids require a .gguf suffix"
  | None -> (
      match Provider.dynamic_model Builtin.local "/tmp/m.gguf" with
      | Some model ->
          equal (option string) ~msg:"gguf display name" (Some "m.gguf")
            (Model.display_name model)
      | None -> failf "expected a dynamic local gguf model")

let all_contracts () =
  equal (list string) ~msg:"all providers are deterministic"
    [ "openai"; "anthropic"; "google"; "deepseek"; "local"; "ollama" ]
    (Builtin.all |> List.map provider_id);
  equal (list string) ~msg:"catalog providers match all"
    [ "openai"; "anthropic"; "google"; "deepseek"; "local"; "ollama" ]
    (Builtin.catalog |> Catalog.providers |> List.map provider_id)

let () =
  run "spice.provider.builtin"
    [
      test "OpenAI contracts" openai_contracts;
      test "Anthropic contracts" anthropic_contracts;
      test "Google contracts" google_contracts;
      test "DeepSeek contracts" deepseek_contracts;
      test "Local contracts" local_contracts;
      test "Ollama contracts" ollama_contracts;
      test "all contracts" all_contracts;
    ]
