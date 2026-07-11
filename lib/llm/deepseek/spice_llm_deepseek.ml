(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm
module Options = Llm.Request.Options
module V4 = Deepseek.V4

let log_src = Logs.Src.create "spice.llm.deepseek" ~doc:"DeepSeek provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( let* ) = Result.bind
let provider = Llm.Provider.make "deepseek"
let api = Llm.Model.Api.make "dsml"
let model id = Llm.Model.make ~provider ~api ~id

let invalid fn message =
  invalid_arg ("Spice_llm_deepseek." ^ fn ^ ": " ^ message)

let check_path fn name = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (name ^ " must not be empty")

let check_positive fn name value =
  if value <= 0 then invalid fn (name ^ " must be positive")

let check_non_negative_finite fn name value =
  if (not (Float.is_finite value)) || value < 0. then
    invalid fn (name ^ " must be finite and non-negative")

module Config = struct
  type t = {
    model_dir : string option;
    cache_dir : string option;
    ctx_size : int;
    max_tokens : int;
    temperature : float;
    top_p : float;
    min_p : float;
    seed : int64;
  }

  let make ?model_dir ?cache_dir ?(ctx_size = 4096) ?(max_tokens = 2048)
      ?(temperature = 1.0) ?(top_p = 1.0) ?(min_p = 0.05)
      ?(seed = 0x2545F4914F6CDD1DL) () =
    check_path "Config.make" "model_dir" model_dir;
    check_path "Config.make" "cache_dir" cache_dir;
    check_positive "Config.make" "ctx_size" ctx_size;
    check_positive "Config.make" "max_tokens" max_tokens;
    check_non_negative_finite "Config.make" "temperature" temperature;
    check_non_negative_finite "Config.make" "top_p" top_p;
    check_non_negative_finite "Config.make" "min_p" min_p;
    {
      model_dir;
      cache_dir;
      ctx_size;
      max_tokens;
      temperature;
      top_p;
      min_p;
      seed;
    }

  let default = make ()
  let backend = V4.backend
end

module Download = struct
  type phase = Checking | Downloading | Verifying | Installed

  type progress = {
    model : string;
    label : string;
    path : string;
    received : int64;
    total : int64 option;
    phase : phase;
  }
end

type artifact = { file : string; url : string; size : int64; sha256 : string }

type target = {
  name : string;
  aliases : string list;
  artifacts : artifact list;
}

let hf_url file =
  "https://huggingface.co/antirez/deepseek-v4-gguf/resolve/main/"
  ^ Uri.pct_encode file

let targets =
  [
    {
      name = "q2-imatrix";
      aliases = [ "q2" ];
      artifacts =
        [
          {
            file =
              "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf";
            url =
              hf_url
                "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf";
            size = 86_720_111_488L;
            sha256 =
              "efc7ed607ff27076e3e501fc3fefefa33c0ed8cf1eff483a2b7fdc0c2e616668";
          };
        ];
    };
    {
      name = "q2-q4-imatrix";
      aliases = [ "q2q4" ];
      artifacts =
        [
          {
            file =
              "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf";
            url =
              hf_url
                "DeepSeek-V4-Flash-Layers37-42Q4KExperts-OtherExpertLayersIQ2XXSGateUp-Q2KDown-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-fixed.gguf";
            size = 97_591_747_456L;
            sha256 =
              "edabc92af63ad8b139f00087fbfc10a4072f37b7597f4fd9ad1dfa6f83002396";
          };
        ];
    };
    {
      name = "q4-imatrix";
      aliases = [ "q4" ];
      artifacts =
        [
          {
            file =
              "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf";
            url =
              hf_url
                "DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf";
            size = 164_633_502_592L;
            sha256 =
              "a2a3b31eca06344b93d32b2095511c4d36f92739a68a599b22047b4b2335d859";
          };
        ];
    };
    {
      name = "pro-q2-imatrix";
      aliases = [ "pro-q2" ];
      artifacts =
        [
          {
            file =
              "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf";
            url =
              hf_url
                "DeepSeek-V4-Pro-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-Instruct-imatrix.gguf";
            size = 464_627_334_560L;
            sha256 =
              "a0314d9c0e16122cd60071079124a2d17185d317c55a8f95ecb3ed3506278a96";
          };
        ];
    };
  ]

let find_target id =
  List.find_opt
    (fun target -> String.equal target.name id || List.mem id target.aliases)
    targets

let llm_error ?(phase = Llm.Error.Startup) kind message =
  Llm.Error.make ~kind ~phase ~provider message

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let startup_provider_error message =
  Error (llm_error Llm.Error.Provider message)

let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "DeepSeek request cancelled"

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid "json_string" ("JSON encode failed: " ^ message)

let default_xdg_dir env_name ~home_suffix =
  match Sys.getenv_opt env_name with
  | Some dir when not (String.is_empty dir) -> Ok dir
  | Some _ | None -> (
      match Sys.getenv_opt "HOME" with
      | Some home when not (String.is_empty home) ->
          Ok (Filename.concat home home_suffix)
      | Some _ | None ->
          Error
            (Printf.sprintf
               "cannot determine %s; set %s or HOME, or pass an explicit path"
               env_name env_name))

let model_dir = function
  | Some dir -> Ok dir
  | None ->
      let ( / ) = Filename.concat in
      default_xdg_dir "XDG_DATA_HOME" ~home_suffix:(".local" / "share" / "ds4")

let cache_dir = function
  | Some dir -> Ok dir
  | None ->
      Result.map
        (fun dir ->
          let ( / ) = Filename.concat in
          dir / "spice" / "deepseek")
        (default_xdg_dir "XDG_CACHE_HOME" ~home_suffix:".cache")

let fs_path env path = Eio.Path.( / ) (Eio.Stdenv.fs env) path

let single_artifact id target =
  match target.artifacts with
  | [ artifact ] -> Ok artifact
  | artifacts ->
      unsupported
        (Printf.sprintf
           "DeepSeek model %S is split across %d files and cannot be loaded as \
            a single GGUF model"
           id (List.length artifacts))

type artifact_status =
  | Installed of { path : string }
  | Missing of { path : string; url : string; size : int64 }
  | Explicit_path of { path : string; exists : bool }

let artifact_status ?(config = Config.default) id =
  match model_dir config.Config.model_dir with
  | Error message -> Error message
  | Ok dir -> (
      match find_target id with
      | Some target -> (
          match single_artifact id target with
          | Error error -> Error (Llm.Error.message error)
          | Ok artifact ->
              let path = Filename.concat dir artifact.file in
              if Sys.file_exists path then Ok (Installed { path })
              else
                Ok (Missing { path; url = artifact.url; size = artifact.size }))
      | None -> Ok (Explicit_path { path = id; exists = Sys.file_exists id }))

let emit_download ~observe_download progress =
  Option.iter (fun observe -> observe progress) observe_download

let download_progress ~observe_download ~model ~artifact ~path ~received ~total
    ~phase =
  emit_download ~observe_download
    { Download.model; label = artifact.file; path; received; total; phase }

let ensure_model_path ?http ?observe_download ~sw ~env ~cancelled config id =
  Eio.Switch.check sw;
  let* () = if cancelled () then Error (cancelled_error ()) else Ok () in
  match model_dir config.Config.model_dir with
  | Error message -> startup_provider_error message
  | Ok dir -> (
      match find_target id with
      | Some target -> (
          let* artifact = single_artifact id target in
          let path = Filename.concat dir artifact.file in
          if Sys.file_exists path then Ok path
          else
            match http with
            | None ->
                startup_provider_error
                  (Printf.sprintf
                     "DeepSeek model %S is not downloaded at %s and automatic \
                      download is unavailable"
                     id path)
            | Some http ->
                Log.info (fun m ->
                    m "downloading model=%s size=%Ld" id artifact.size);
                let observe phase ~received ~total =
                  let phase =
                    match phase with
                    | Spice_llm_artifact.Checking -> Download.Checking
                    | Spice_llm_artifact.Downloading -> Download.Downloading
                    | Spice_llm_artifact.Verifying -> Download.Verifying
                    | Spice_llm_artifact.Installed -> Download.Installed
                  in
                  download_progress ~observe_download ~model:id ~artifact ~path
                    ~received ~total ~phase
                in
                let* () =
                  Spice_llm_artifact.install ~env ~http ~provider ~cancelled
                    ~observe ~url:artifact.url ~path ~size:artifact.size
                    ~sha256:artifact.sha256
                in
                Log.info (fun m -> m "model installed model=%s path=%s" id path);
                Ok path)
      | None ->
          if Sys.file_exists id then Ok id
          else
            startup_provider_error
              (Printf.sprintf "DeepSeek model path does not exist: %s" id))

module Artifact = struct
  type status = artifact_status =
    | Installed of { path : string }
    | Missing of { path : string; url : string; size : int64 }
    | Explicit_path of { path : string; exists : bool }

  let status = artifact_status

  let prepare ~sw ~env ~http ~cancelled ?observe_download
      ?(config = Config.default) id =
    ensure_model_path ~sw ~env ~http ?observe_download ~cancelled config id
    |> Result.map ignore
end

let text_of_content context content =
  let rec loop acc = function
    | [] -> Ok (String.concat "\n\n" (List.rev acc))
    | Llm.Content.Text text :: rest -> loop (text :: acc) rest
    | Llm.Content.Media _ :: _ ->
        unsupported (context ^ " contains media, but DeepSeek DSML accepts text")
  in
  loop [] content

let tool_result_text result =
  match text_of_content "tool result" (Llm.Tool.Result.content result) with
  | Ok text ->
      if Llm.Tool.Result.is_error result && not (String.is_empty text) then
        Ok ("Error: " ^ text)
      else Ok text
  | Error _ as error -> error

let dsml_tool tool =
  Dsml.Tool.v ~name:(Llm.Tool.name tool)
    ?description:(Llm.Tool.description tool)
    ~parameters:(Llm.Tool.input_schema tool)
    ()

let dsml_tool_call call =
  Dsml.tool_call ~id:(Llm.Tool.Call.id call) ~name:(Llm.Tool.Call.name call)
    ~arguments:(json_string (Llm.Tool.Call.input call))
    ()

let assistant_message assistant =
  let content = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let calls = ref [] in
  List.iter
    (function
      | Llm.Message.Assistant.Text text -> Buffer.add_string content text
      | Llm.Message.Assistant.Tool_call call ->
          calls := dsml_tool_call call :: !calls
      | Llm.Message.Assistant.Reasoning reasoning_part ->
          Option.iter
            (Buffer.add_string reasoning)
            (Llm.Message.Assistant.Reasoning.text reasoning_part))
    (Llm.Message.Assistant.parts assistant);
  Dsml.assistant ~content:(Buffer.contents content)
    ~reasoning_content:(Buffer.contents reasoning)
    ~tool_calls:(List.rev !calls) ()

let encode_message = function
  | Llm.Message.System text -> Ok (Dsml.system text)
  | Llm.Message.Developer text -> Ok (Dsml.developer text)
  | Llm.Message.User content ->
      Result.map
        (fun text -> Dsml.user text)
        (text_of_content "user message" content)
  | Llm.Message.Assistant assistant -> Ok (assistant_message assistant)
  | Llm.Message.Tool_result result ->
      Result.map
        (Dsml.tool ~id:(Llm.Tool.Result.call_id result))
        (tool_result_text result)

let encode_messages request =
  let tools =
    match Options.tool_choice (Llm.Request.options request) with
    | Options.No_tools -> []
    | Options.Auto -> List.map dsml_tool (Llm.Request.tools request)
    | Options.Required | Options.Tool _ -> []
  in
  let rec loop attached acc = function
    | [] ->
        let messages = List.rev acc in
        if attached || List.is_empty tools then Ok messages
        else
          Ok
            (Dsml.system ~tools "You are Spice, an OCaml coding agent."
            :: messages)
    | Llm.Message.System text :: rest when not attached ->
        loop true (Dsml.system ~tools text :: acc) rest
    | Llm.Message.Developer text :: rest when not attached ->
        loop true (Dsml.developer ~tools text :: acc) rest
    | message :: rest -> (
        match encode_message message with
        | Error _ as error -> error
        | Ok message -> loop attached (message :: acc) rest)
  in
  loop false [] (Llm.Request.messages request)

let check_request request =
  let options = Llm.Request.options request in
  match Options.response_format options with
  | Options.Json_schema _ ->
      unsupported "DeepSeek DSML adapter does not support JSON-schema responses"
  | Options.Text -> (
      match Options.tool_choice options with
      | Options.Auto | Options.No_tools -> Ok ()
      | Options.Required ->
          unsupported "DeepSeek DSML adapter does not support required tool use"
      | Options.Tool name ->
          unsupported
            (Printf.sprintf
               "DeepSeek DSML adapter does not support forcing tool %S" name))

let thinking_mode options =
  match Options.reasoning_effort options with
  | None | Some Options.Reasoning_effort.Disabled -> Ok (Dsml.Chat, None)
  | Some Options.Reasoning_effort.High -> Ok (Dsml.Thinking, Some Dsml.High)
  | Some Options.Reasoning_effort.Max -> Ok (Dsml.Thinking, Some Dsml.Max)
  | Some Options.Reasoning_effort.Minimal
  | Some Options.Reasoning_effort.Low
  | Some Options.Reasoning_effort.Medium
  | Some Options.Reasoning_effort.Extra_high ->
      unsupported
        "DeepSeek DSML adapter supports reasoning efforts none, high, and max"

type loaded = {
  engine : V4.engine;
  sessions : (string, V4.Session.t) Hashtbl.t;
}

let load_engine ~sw ~env config path =
  match cache_dir config.Config.cache_dir with
  | Error message -> startup_provider_error message
  | Ok cache_dir -> (
      try
        let cache = fs_path env cache_dir in
        Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 cache;
        let model = fs_path env path in
        Ok
          (V4.create ~sw
             ~domain_mgr:(Eio.Stdenv.domain_mgr env)
             ~cache ~model ())
      with Failure message -> startup_provider_error message)

let assistant_of_parts reasoning content calls =
  let parts = [] in
  let parts =
    if String.is_empty reasoning then parts
    else
      parts
      @ [
          Llm.Message.Assistant.reasoning_part
            (Llm.Message.Assistant.Reasoning.make ~text:reasoning ());
        ]
  in
  let parts =
    if String.is_empty content then parts
    else parts @ [ Llm.Message.Assistant.text_part content ]
  in
  let parts = parts @ List.map Llm.Message.Assistant.tool_call calls in
  match parts with
  | [] -> Llm.Message.Assistant.empty
  | parts -> Llm.Message.Assistant.make parts

let response ~model ~stop ~provider_stop reasoning content calls =
  Llm.Response.make ~model ~provider_stop ~stop
    (assistant_of_parts reasoning content calls)

let decode_tool_call index (call : Dsml.tool_call) =
  let id =
    match call.Dsml.id with
    | Some id -> id
    | None -> Printf.sprintf "deepseek_call_%d" index
  in
  match Dsml.Json.Value.of_string call.Dsml.arguments with
  | Error message ->
      Error
        (stream_error Llm.Error.Decode
           ("DeepSeek tool-call arguments are not JSON: " ^ message))
  | Ok input -> (
      try Ok (Llm.Tool.Call.make ~id ~name:call.Dsml.name ~input ())
      with Invalid_argument message ->
        Error (stream_error Llm.Error.Decode message))

let stream_of_session ~cancelled ~config ~engine ~session ~request ~mode
    ?reasoning_effort messages =
  let prompt = Dsml.encode_messages ?reasoning_effort mode messages in
  let tokens = V4.Session.tokenize engine prompt in
  V4.Session.sync session tokens;
  let room = V4.Session.ctx session - V4.Session.pos session in
  let requested =
    Option.value
      (Options.max_output_tokens (Llm.Request.options request))
      ~default:config.Config.max_tokens
  in
  let budget = if room <= 1 then 0 else min requested (room - 1) in
  let temperature =
    Option.value
      (Options.temperature (Llm.Request.options request))
      ~default:config.Config.temperature
  in
  let decoder = Dsml.Stream.create mode in
  let eos = V4.token_eos engine in
  let generated = ref 0 in
  let pending = Queue.create () in
  let content = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let calls = ref [] in
  let call_count = ref 0 in
  let terminal = ref None in
  let model = Llm.Request.model request in
  let finish stop provider_stop =
    Log.debug (fun m ->
        m "generation finished model=%s tokens=%d calls=%d stop=%s"
          (Llm.Model.id model) !generated !call_count
          (Llm.Response.Stop.label stop));
    let response =
      response ~model ~stop ~provider_stop
        (Buffer.contents reasoning)
        (Buffer.contents content) (List.rev !calls)
    in
    terminal := Some (Llm.Stream.Finished response)
  in
  let fail error = terminal := Some (Llm.Stream.Failed error) in
  let enqueue_dsml_event event =
    if Option.is_none !terminal then
      match event with
      | Dsml.Stream.Content text ->
          Buffer.add_string content text;
          Queue.add
            (Llm.Stream.Event (Llm.Stream.Event.text_delta text))
            pending
      | Dsml.Stream.Reasoning text ->
          Buffer.add_string reasoning text;
          Queue.add
            (Llm.Stream.Event (Llm.Stream.Event.reasoning_summary_delta text))
            pending
      | Dsml.Stream.Tool_call call -> (
          match decode_tool_call !call_count call with
          | Error error -> fail error
          | Ok call ->
              incr call_count;
              calls := call :: !calls;
              Queue.add
                (Llm.Stream.Event (Llm.Stream.Event.tool_call call))
                pending)
      | Dsml.Stream.Done -> ()
  in
  let flush_finish stop provider_stop =
    List.iter enqueue_dsml_event (Dsml.Stream.finish decoder);
    if Option.is_none !terminal then finish stop provider_stop
  in
  let rec next () =
    match Queue.take_opt pending with
    | Some item -> Some item
    | None -> (
        match !terminal with
        | Some item ->
            terminal := None;
            Some item
        | None ->
            if cancelled () then begin
              Log.debug (fun m ->
                  m "generation cancelled model=%s tokens=%d"
                    (Llm.Model.id model) !generated);
              fail (cancelled_error ~phase:Llm.Error.Stream ());
              next ()
            end
            else if !generated >= budget then begin
              flush_finish Llm.Response.Stop.length
                (Llm.Response.Stop.label Llm.Response.Stop.length);
              next ()
            end
            else
              let token =
                V4.Session.sample session ~temperature
                  ~top_p:config.Config.top_p ~min_p:config.Config.min_p
              in
              if Int.equal token eos then begin
                let stop =
                  if List.is_empty !calls then Llm.Response.Stop.end_turn
                  else Llm.Response.Stop.tool_call
                in
                flush_finish stop (Llm.Response.Stop.label stop);
                next ()
              end
              else begin
                incr generated;
                V4.Session.eval session token;
                List.iter enqueue_dsml_event
                  (Dsml.Stream.feed decoder (V4.token_text engine token));
                next ()
              end)
  in
  Llm.Stream.make next

let client ~sw ~env ?http ?observe_download ?(config = Config.default) () =
  let loaded_by_model = Hashtbl.create 4 in
  let session loaded request =
    match Llm.Request.cache_key request with
    | None ->
        V4.Session.create loaded.engine ~ctx_size:config.Config.ctx_size
          ~seed:config.Config.seed
    | Some cache_key -> (
        match Hashtbl.find_opt loaded.sessions cache_key with
        | Some session -> session
        | None ->
            let session =
              V4.Session.create loaded.engine ~ctx_size:config.Config.ctx_size
                ~seed:config.Config.seed
            in
            Hashtbl.add loaded.sessions cache_key session;
            session)
  in
  let accepts model =
    Llm.Provider.equal provider (Llm.Model.provider model)
    && Llm.Model.Api.equal api (Llm.Model.api model)
  in
  let run ~cancelled ~on_event request =
    if cancelled () then Error (cancelled_error ())
    else
      let* () = check_request request in
      let* mode, reasoning_effort =
        thinking_mode (Llm.Request.options request)
      in
      let* messages = encode_messages request in
      let* loaded =
        let model = Llm.Request.model request in
        let id = Llm.Model.id model in
        match Hashtbl.find_opt loaded_by_model id with
        | Some loaded -> Ok loaded
        | None ->
            let* path =
              ensure_model_path ?http ?observe_download ~sw ~env ~cancelled
                config id
            in
            let* engine = load_engine ~sw ~env config path in
            Log.info (fun m -> m "engine loaded model=%s" id);
            let loaded = { engine; sessions = Hashtbl.create 4 } in
            Hashtbl.add loaded_by_model id loaded;
            Ok loaded
      in
      Llm.Stream.iter_events
        (stream_of_session ~cancelled ~config ~engine:loaded.engine
           ~session:(session loaded request) ~request ~mode ?reasoning_effort
           messages)
        ~f:on_event
  in
  Llm.Client.make ~provider ~accepts ~run ()
