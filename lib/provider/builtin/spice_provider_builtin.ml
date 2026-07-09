(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Capability = Spice_provider.Model.Capability
module Date = Spice_provider.Model.Date
module Auth = Spice_provider.Auth
module Env = Auth.Env
module Model = Spice_provider.Model
module Modality = Spice_provider.Model.Modality
module Options = Spice_llm.Request.Options
module Provider = Spice_provider

(* Model metadata follows the providers' published facts; only native model
   ids are declared, never synthetic modes or aliases Spice would have to
   reinterpret. *)

let invalid message = invalid_arg ("Spice_provider_builtin: " ^ message)

let date text =
  match Date.of_string text with
  | Some date -> date
  | None -> invalid ("invalid built-in model release date: " ^ text)

let text_image = [ Modality.text; Modality.image ]
let text_image_pdf = [ Modality.text; Modality.image; Modality.pdf ]

let text_image_audio_video_pdf =
  [
    Modality.text; Modality.image; Modality.audio; Modality.video; Modality.pdf;
  ]

let reasoning_json_schema = [ Capability.reasoning; Capability.json_schema ]
let tools_reasoning = [ Capability.tools; Capability.reasoning ]

let tools_reasoning_json_schema =
  [ Capability.tools; Capability.reasoning; Capability.json_schema ]

(* The GPT-5.x coding models are trained on the apply_patch edit format, so they
   receive the [apply-patch] editor family. This is deliberately not shared with
   the local gpt-oss models (not trained on apply_patch) nor the gpt-image model
   (not a coding model), which keep [tools_reasoning_json_schema]. *)
let gpt_coding_capabilities =
  tools_reasoning_json_schema @ [ Capability.extension "apply-patch" ]

let gpt5_efforts =
  Options.Reasoning_effort.[ Disabled; Low; Medium; High; Extra_high ]

let opus_47_efforts =
  Options.Reasoning_effort.[ Low; Medium; High; Extra_high; Max ]

let claude_46_efforts = Options.Reasoning_effort.[ Low; Medium; High; Max ]
let gemini_3_pro_efforts = Options.Reasoning_effort.[ Low; High ]

let gemini_3_flash_efforts =
  Options.Reasoning_effort.[ Minimal; Low; Medium; High ]

let gemini_25_efforts = Options.Reasoning_effort.[ High; Max ]
let deepseek_efforts = Options.Reasoning_effort.[ Disabled; High; Max ]
let local_efforts = Options.Reasoning_effort.[ Disabled; Low; Medium; High ]
let tools_json_schema = [ Capability.tools; Capability.json_schema ]

let tier ?cache_read ?cache_write ~context_over ~input ~output () =
  let rate =
    Model.price ~input_per_million:input ?cached_input_per_million:cache_read
      ~output_per_million:output ?cache_write_5m_per_million:cache_write ()
  in
  (context_over, rate)

let pricing ?(tiers = []) ?cache_read ?cache_write ~input ~output () =
  let default =
    Model.price ~input_per_million:input ?cached_input_per_million:cache_read
      ~output_per_million:output ?cache_write_5m_per_million:cache_write ()
  in
  Model.make_pricing ~context_over:tiers default

let gpt_5_chat_unavailable =
  Model.Unavailable "OpenAI Responses does not support this chat alias"

(* The built-in catalog is a curated, current-generation coding set, not a
   historical archive. Image models stay declared so capability gates can
   name a real model; chat aliases stay declared so their unavailability
   reason beats an unknown-model error. *)

let openai_models =
  let llm = Spice_llm_openai.model in
  [
    Model.make (llm "gpt-5.5") ~display_name:"GPT-5.5" ~family:"gpt"
      ~released_on:(date "2026-04-23") ~context_window:1_050_000
      ~max_output_tokens:128_000 ~input_modalities:text_image_pdf
      ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:
        (pricing ~input:5. ~output:30. ~cache_read:0.5
           ~tiers:
             [
               tier ~context_over:272_000 ~input:10. ~output:45. ~cache_read:1.
                 ();
             ]
           ())
      ();
    Model.make (llm "gpt-5.5-pro") ~display_name:"GPT-5.5 Pro"
      ~family:"gpt-pro" ~released_on:(date "2026-04-23")
      ~context_window:1_050_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:
        (pricing ~input:30. ~output:180.
           ~tiers:[ tier ~context_over:272_000 ~input:60. ~output:270. () ]
           ())
      ();
    Model.make (llm "gpt-5.4") ~display_name:"GPT-5.4" ~family:"gpt"
      ~released_on:(date "2026-03-05") ~context_window:1_050_000
      ~max_output_tokens:128_000 ~input_modalities:text_image_pdf
      ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:
        (pricing ~input:2.5 ~output:15. ~cache_read:0.25
           ~tiers:
             [
               tier ~context_over:272_000 ~input:5. ~output:22.5 ~cache_read:0.5
                 ();
             ]
           ())
      ();
    Model.make (llm "gpt-5.4-pro") ~display_name:"GPT-5.4 Pro"
      ~family:"gpt-pro" ~released_on:(date "2026-03-05")
      ~context_window:1_050_000 ~max_output_tokens:128_000
      ~input_modalities:text_image ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:
        (pricing ~input:30. ~output:180.
           ~tiers:[ tier ~context_over:272_000 ~input:60. ~output:270. () ]
           ())
      ();
    Model.make (llm "gpt-5.4-mini") ~display_name:"GPT-5.4 mini"
      ~family:"gpt-mini" ~released_on:(date "2026-03-17")
      ~context_window:400_000 ~max_output_tokens:128_000
      ~input_modalities:text_image ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:(pricing ~input:0.75 ~output:4.5 ~cache_read:0.075 ())
      ();
    Model.make (llm "gpt-5.4-nano") ~display_name:"GPT-5.4 nano"
      ~family:"gpt-nano" ~released_on:(date "2026-03-17")
      ~context_window:400_000 ~max_output_tokens:128_000
      ~input_modalities:text_image ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:(pricing ~input:0.2 ~output:1.25 ~cache_read:0.02 ())
      ();
    Model.make (llm "gpt-5.3-codex") ~display_name:"GPT-5.3 Codex"
      ~family:"gpt-codex" ~released_on:(date "2026-02-05")
      ~context_window:400_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:(pricing ~input:1.75 ~output:14. ~cache_read:0.175 ())
      ();
    Model.make (llm "gpt-5.2") ~display_name:"GPT-5.2" ~family:"gpt"
      ~released_on:(date "2025-12-11") ~context_window:400_000
      ~max_output_tokens:128_000 ~input_modalities:text_image
      ~capabilities:gpt_coding_capabilities
      ~default_reasoning:Options.Reasoning_effort.Medium
      ~supported_reasoning:gpt5_efforts
      ~pricing:(pricing ~input:1.75 ~output:14. ~cache_read:0.175 ())
      ();
    Model.make (llm "gpt-image-1.5") ~display_name:"gpt-image-1.5"
      ~family:"gpt-image" ~released_on:(date "2025-11-25")
      ~input_modalities:text_image ~output_modalities:text_image ();
    Model.make (llm "gpt-5-chat-latest") ~display_name:"GPT-5 Chat (latest)"
      ~family:"gpt-codex" ~released_on:(date "2025-08-07")
      ~context_window:400_000 ~max_output_tokens:128_000
      ~input_modalities:text_image ~capabilities:reasoning_json_schema
      ~pricing:(pricing ~input:1.25 ~output:10. ())
      ~status:gpt_5_chat_unavailable ();
  ]

let anthropic_models =
  let llm = Spice_llm_anthropic.model in
  [
    Model.make (llm "claude-sonnet-5") ~display_name:"Claude Sonnet 5"
      ~family:"claude-sonnet" ~released_on:(date "2026-06-29")
      ~context_window:1_000_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:claude_46_efforts
      ~pricing:
        (pricing ~input:2. ~output:10. ~cache_read:0.2 ~cache_write:2.5 ())
      ();
    Model.make (llm "claude-fable-5") ~display_name:"Claude Fable 5"
      ~family:"claude-fable" ~released_on:(date "2026-06-07")
      ~context_window:1_000_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:claude_46_efforts
      ~pricing:
        (pricing ~input:10. ~output:50. ~cache_read:1. ~cache_write:12.5 ())
      ();
    Model.make (llm "claude-opus-4-8") ~display_name:"Claude Opus 4.8"
      ~family:"claude-opus" ~released_on:(date "2026-05-28")
      ~context_window:1_000_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:opus_47_efforts
      ~pricing:
        (pricing ~input:5. ~output:25. ~cache_read:0.5 ~cache_write:6.25 ())
      ();
    Model.make (llm "claude-opus-4-7") ~display_name:"Claude Opus 4.7"
      ~family:"claude-opus" ~released_on:(date "2026-04-16")
      ~context_window:1_000_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:opus_47_efforts
      ~pricing:
        (pricing ~input:5. ~output:25. ~cache_read:0.5 ~cache_write:6.25 ())
      ();
    Model.make (llm "claude-opus-4-6") ~display_name:"Claude Opus 4.6"
      ~family:"claude-opus" ~released_on:(date "2026-02-05")
      ~context_window:1_000_000 ~max_output_tokens:128_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:claude_46_efforts
      ~pricing:
        (pricing ~input:5. ~output:25. ~cache_read:0.5 ~cache_write:6.25 ())
      ();
    Model.make (llm "claude-sonnet-4-6") ~display_name:"Claude Sonnet 4.6"
      ~family:"claude-sonnet" ~released_on:(date "2026-02-17")
      ~context_window:1_000_000 ~max_output_tokens:64_000
      ~input_modalities:text_image_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:claude_46_efforts
      ~pricing:
        (pricing ~input:3. ~output:15. ~cache_read:0.3 ~cache_write:3.75 ())
      ();
    Model.make (llm "claude-haiku-4-5")
      ~display_name:"Claude Haiku 4.5 (latest)" ~family:"claude-haiku"
      ~released_on:(date "2025-10-15") ~context_window:200_000
      ~max_output_tokens:64_000 ~input_modalities:text_image_pdf
      ~capabilities:tools_reasoning
      ~pricing:
        (pricing ~input:1. ~output:5. ~cache_read:0.1 ~cache_write:1.25 ())
      ();
  ]

let google_models =
  let llm = Spice_llm_google.model in
  [
    Model.make (llm "gemini-3.5-flash") ~display_name:"Gemini 3.5 Flash"
      ~family:"gemini-flash" ~released_on:(date "2026-05-19")
      ~context_window:1_048_576 ~max_output_tokens:65_536
      ~input_modalities:text_image_audio_video_pdf
      ~capabilities:tools_reasoning ~supported_reasoning:gemini_3_flash_efforts
      ~pricing:(pricing ~input:1.5 ~output:9. ~cache_read:0.15 ())
      ();
    Model.make (llm "gemini-3.1-pro-preview")
      ~display_name:"Gemini 3.1 Pro Preview" ~family:"gemini-pro"
      ~released_on:(date "2026-02-19") ~context_window:1_048_576
      ~max_output_tokens:65_536 ~input_modalities:text_image_audio_video_pdf
      ~capabilities:tools_reasoning ~supported_reasoning:gemini_3_pro_efforts
      ~status:Model.Preview
      ~pricing:
        (pricing ~input:2. ~output:12. ~cache_read:0.2
           ~tiers:
             [
               tier ~context_over:200_000 ~input:4. ~output:18. ~cache_read:0.4
                 ();
             ]
           ())
      ();
    Model.make (llm "gemini-3.1-flash-lite")
      ~display_name:"Gemini 3.1 Flash Lite" ~family:"gemini-flash-lite"
      ~released_on:(date "2026-05-07") ~context_window:1_048_576
      ~max_output_tokens:65_536 ~input_modalities:text_image_audio_video_pdf
      ~capabilities:tools_reasoning ~supported_reasoning:gemini_3_flash_efforts
      ~pricing:(pricing ~input:0.25 ~output:1.5 ~cache_read:0.025 ())
      ();
    Model.make
      (llm "gemini-3-pro-preview")
      ~display_name:"Gemini 3 Pro Preview" ~family:"gemini-pro"
      ~released_on:(date "2025-11-18") ~context_window:1_048_576
      ~max_output_tokens:65_536 ~input_modalities:text_image_audio_video_pdf
      ~capabilities:tools_reasoning ~supported_reasoning:gemini_3_pro_efforts
      ~status:Model.Deprecated
      ~pricing:
        (pricing ~input:2. ~output:12. ~cache_read:0.2
           ~tiers:
             [
               tier ~context_over:200_000 ~input:4. ~output:18. ~cache_read:0.4
                 ();
             ]
           ())
      ();
    Model.make
      (llm "gemini-3-flash-preview")
      ~display_name:"Gemini 3 Flash Preview" ~family:"gemini-flash"
      ~released_on:(date "2025-12-17") ~context_window:1_048_576
      ~max_output_tokens:65_536 ~input_modalities:text_image_audio_video_pdf
      ~capabilities:tools_reasoning ~supported_reasoning:gemini_3_flash_efforts
      ~status:Model.Preview
      ~pricing:(pricing ~input:0.5 ~output:3. ~cache_read:0.05 ())
      ();
    Model.make (llm "gemini-2.5-flash") ~display_name:"Gemini 2.5 Flash"
      ~family:"gemini-flash" ~released_on:(date "2025-06-17")
      ~context_window:1_048_576 ~max_output_tokens:65_536
      ~input_modalities:text_image_audio_video_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:gemini_25_efforts
      ~pricing:(pricing ~input:0.3 ~output:2.5 ~cache_read:0.03 ())
      ();
    Model.make (llm "gemini-2.5-pro") ~display_name:"Gemini 2.5 Pro"
      ~family:"gemini-pro" ~released_on:(date "2025-06-17")
      ~context_window:1_048_576 ~max_output_tokens:65_536
      ~input_modalities:text_image_audio_video_pdf ~capabilities:tools_reasoning
      ~supported_reasoning:gemini_25_efforts
      ~pricing:
        (pricing ~input:1.25 ~output:10. ~cache_read:0.125
           ~tiers:
             [
               tier ~context_over:200_000 ~input:2.5 ~output:15.
                 ~cache_read:0.25 ();
             ]
           ())
      ();
  ]

let deepseek_models =
  let llm = Spice_llm_deepseek.model in
  [
    Model.make (llm "q2-imatrix") ~display_name:"DeepSeek V4 Flash q2"
      ~family:"deepseek-v4-flash" ~context_window:4096 ~max_output_tokens:2048
      ~capabilities:tools_reasoning
      ~default_reasoning:Options.Reasoning_effort.Disabled
      ~supported_reasoning:deepseek_efforts ();
    Model.make (llm "q2-q4-imatrix") ~display_name:"DeepSeek V4 Flash q2/q4"
      ~family:"deepseek-v4-flash" ~context_window:4096 ~max_output_tokens:2048
      ~capabilities:tools_reasoning
      ~default_reasoning:Options.Reasoning_effort.Disabled
      ~supported_reasoning:deepseek_efforts ();
    Model.make (llm "q4-imatrix") ~display_name:"DeepSeek V4 Flash q4"
      ~family:"deepseek-v4-flash" ~context_window:4096 ~max_output_tokens:2048
      ~capabilities:tools_reasoning
      ~default_reasoning:Options.Reasoning_effort.Disabled
      ~supported_reasoning:deepseek_efforts ();
    Model.make (llm "pro-q2-imatrix") ~display_name:"DeepSeek V4 Pro q2"
      ~family:"deepseek-v4-pro" ~context_window:4096 ~max_output_tokens:2048
      ~capabilities:tools_reasoning
      ~default_reasoning:Options.Reasoning_effort.Disabled
      ~supported_reasoning:deepseek_efforts ();
  ]

(* The local catalog derives from the curated manifest so ids, display
   names, and context windows cannot drift from the artifacts the adapter
   downloads and serves. *)
let local_models =
  let local_model entry =
    let llm = Spice_llm_local.model (Spice_llm_local.Manifest.id entry) in
    let display_name = Spice_llm_local.Manifest.display_name entry in
    let family = Spice_llm_local.Manifest.family entry in
    let context_window = Spice_llm_local.Manifest.context_length entry in
    if Spice_llm_local.Manifest.reasoning entry then
      Model.make llm ~display_name ~family ~context_window
        ~max_output_tokens:16_384 ~capabilities:tools_reasoning_json_schema
        ~default_reasoning:Options.Reasoning_effort.Medium
        ~supported_reasoning:local_efforts ()
    else
      Model.make llm ~display_name ~family ~context_window
        ~max_output_tokens:16_384 ~capabilities:tools_json_schema ()
  in
  List.map local_model Spice_llm_local.Manifest.all

module Openai_auth = struct
  let issuer = Uri.of_string "https://auth.openai.com"
  let client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
  let browser_redirect_uri = Uri.of_string "http://localhost:1455/auth/callback"

  let trim_right_slashes path =
    let rec loop i =
      if i <= 0 then ""
      else if Char.equal (String.unsafe_get path (i - 1)) '/' then loop (i - 1)
      else String.sub path 0 i
    in
    loop (String.length path)

  let append_path suffix =
    let base = trim_right_slashes (Uri.path issuer) in
    let suffix =
      if String.starts_with ~prefix:"/" suffix then suffix else "/" ^ suffix
    in
    let uri = Uri.with_path issuer (base ^ suffix) in
    Uri.with_fragment (Uri.with_query' uri []) None

  let authorization_endpoint = append_path "/oauth/authorize"
  let oauth_token_endpoint = append_path "/oauth/token"
end

let openai_auth =
  let client = Oauth2.Client.make ~id:Openai_auth.client_id () in
  let browser =
    Auth.Login.oauth2_authorization_code ~client
      ~authorization_endpoint:Openai_auth.authorization_endpoint
      ~token_endpoint:Openai_auth.oauth_token_endpoint
      ~redirect_uri:Openai_auth.browser_redirect_uri
      ~scope:[ "openid"; "profile"; "email"; "offline_access" ]
      ~extra:
        [
          ("id_token_add_organizations", "true");
          ("codex_cli_simplified_flow", "true");
          ("originator", "opencode");
        ]
      ()
  in
  let device_code =
    Auth.Login.make ~id:"device-code" ~label:"OpenAI ChatGPT device code"
      (Auth.Login.Protocol.Provider_device_code
         { provider_flow = "openai_chatgpt" })
  in
  Auth.make
    ~env:[ Env.api_key "OPENAI_API_KEY" ]
    ~login:[ browser; device_code; Auth.Login.api_key () ]
    ()

let anthropic_auth =
  Auth.make
    ~env:[ Env.api_key "ANTHROPIC_API_KEY" ]
    ~login:[ Auth.Login.api_key () ]
    ()

let google_auth =
  Auth.make
    ~env:
      [
        Env.api_key "GOOGLE_API_KEY";
        Env.api_key "GOOGLE_GENERATIVE_AI_API_KEY";
        Env.api_key "GEMINI_API_KEY";
      ]
    ~login:[ Auth.Login.api_key () ]
    ()

let openai =
  Provider.make Spice_llm_openai.provider ~display_name:"OpenAI"
    ~default_model:(Spice_llm_openai.model "gpt-5.5")
    ~auth:openai_auth openai_models

let anthropic =
  Provider.make Spice_llm_anthropic.provider ~display_name:"Anthropic"
    ~default_model:(Spice_llm_anthropic.model "claude-sonnet-5")
    ~auth:anthropic_auth anthropic_models

let google =
  Provider.make Spice_llm_google.provider ~display_name:"Google"
    ~default_model:(Spice_llm_google.model "gemini-3.5-flash")
    ~auth:google_auth google_models

(* Local-weights providers interpret undeclared [.gguf] ids as explicit
   filesystem paths at request time; other undeclared ids stay unknown so
   typos keep their hints. *)
let gguf_dynamic_model llm capabilities id =
  if String.ends_with ~suffix:".gguf" id then
    Some
      (Model.make (llm id) ~display_name:(Filename.basename id) ~family:"gguf"
         ~capabilities ())
  else None

let deepseek =
  Provider.make Spice_llm_deepseek.provider ~display_name:"DeepSeek"
    ~default_model:(Spice_llm_deepseek.model "q2-q4-imatrix")
    ~dynamic_model:
      (gguf_dynamic_model Spice_llm_deepseek.model [ Capability.tools ])
    deepseek_models

let local =
  Provider.make Spice_llm_local.provider ~display_name:"Local"
    ~default_model:(Spice_llm_local.model "qwen3-coder-30b")
    ~dynamic_model:(gguf_dynamic_model Spice_llm_local.model tools_json_schema)
    local_models

(* Authentication is optional: the default daemon serves bare on localhost,
   while a remote or proxied deployment may demand a key — a fact of the
   deployment, not the provider, hence [~required:false]. *)
let ollama_auth =
  Auth.make ~required:false
    ~env:[ Env.api_key "OLLAMA_API_KEY" ]
    ~login:[ Auth.Login.api_key () ]
    ()

(* The Ollama daemon owns its model set, so the declaration lists none and
   every id is dynamic: whether ["qwen3-coder:30b"] exists is the daemon's
   runtime answer, not catalog data. *)
let ollama =
  Provider.make Spice_llm_ollama.provider ~display_name:"Ollama"
    ~auth:ollama_auth
    ~dynamic_model:(fun id ->
      if String.is_empty id then None
      else
        Some
          (Model.make
             (Spice_llm_ollama.model id)
             ~display_name:id ~family:"ollama" ~capabilities:tools_json_schema
             ()))
    []

let all = [ openai; anthropic; google; deepseek; local; ollama ]

let catalog =
  match Provider.Catalog.of_list all with
  | Ok catalog -> catalog
  | Error provider ->
      invalid
        ("provider "
        ^ Spice_llm.Provider.id provider
        ^ " is declared more than once")
