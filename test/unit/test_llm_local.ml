(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Local = Spice_llm_local
module Json = Jsont.Json

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok text -> text
  | Error message -> failf "JSON encode failed: %s" message

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok json -> json
  | Error message -> failf "JSON decode failed: %s" message

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let equal_error_kind msg kind error =
  equal string ~msg (Llm.Error.label kind)
    (Llm.Error.label (Llm.Error.kind error))

let string_field msg name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> value
  | Some _ | None -> failf "%s: missing string field %s" msg name

let list_field msg name json =
  match object_field name json with
  | Some (Jsont.Array (items, _)) -> items
  | Some _ | None -> failf "%s: missing array field %s" msg name

(* Manifest *)

let manifest_integrity () =
  let ids = List.map Local.Manifest.id Local.Manifest.all in
  equal int ~msg:"manifest ids are unique" (List.length ids)
    (List.length (List.sort_uniq String.compare ids));
  check "manifest is non-empty" (not (List.is_empty Local.Manifest.all));
  List.iter
    (fun entry ->
      let id = Local.Manifest.id entry in
      check (id ^ " findable") (Option.is_some (Local.Manifest.find id));
      check (id ^ " size positive")
        (Int64.compare (Local.Manifest.size entry) 0L > 0);
      check
        (id ^ " url is huggingface")
        (String.starts_with ~prefix:"https://huggingface.co/"
           (Local.Manifest.url entry));
      check (id ^ " context positive") (Local.Manifest.context_length entry > 0);
      let fit = Local.Manifest.fit entry in
      check
        (id ^ " fits an unconstrained budget")
        (match Spice_modelfit.verdict ~budget:max_int fit with
        | Spice_modelfit.Verdict.Fits -> true
        | Spice_modelfit.Verdict.Tight _ | Spice_modelfit.Verdict.Wont_run ->
            false))
    Local.Manifest.all

let model_contracts () =
  let model = Local.model "qwen3-coder-30b" in
  check "model provider"
    (Llm.Provider.equal (Llm.Model.provider model) Local.provider);
  check "model api" (Llm.Model.Api.equal (Llm.Model.api model) Local.api);
  expect_invalid_arg "ctx_size must be positive" (fun () ->
      Local.Config.make ~ctx_size:0 ());
  expect_invalid_arg "memory_budget must be positive" (fun () ->
      Local.Config.make ~memory_budget:0 ())

(* Fit verdicts *)

let gib = 1024 * 1024 * 1024

let expect_fit msg = function
  | Some fit -> fit
  | None -> failf "%s: expected a fit verdict" msg

let fit_verdicts () =
  let config budget = Local.Config.make ~memory_budget:budget () in
  let ample =
    expect_fit "24 GiB"
      (Local.Fit.find ~config:(config (24 * gib)) "gpt-oss-20b")
  in
  check "fits at 24 GiB"
    (match ample.Local.Fit.verdict with
    | Spice_modelfit.Verdict.Fits -> true
    | Spice_modelfit.Verdict.Tight _ | Spice_modelfit.Verdict.Wont_run -> false);
  equal int ~msg:"budget is echoed" (24 * gib) ample.Local.Fit.budget_bytes;
  check "fit renders as fits"
    (String.starts_with ~prefix:"fits" (Local.Fit.to_string ample));
  let starved =
    expect_fit "8 GiB" (Local.Fit.find ~config:(config (8 * gib)) "gpt-oss-20b")
  in
  check "won't run at 8 GiB"
    (match starved.Local.Fit.verdict with
    | Spice_modelfit.Verdict.Wont_run -> true
    | Spice_modelfit.Verdict.Fits | Spice_modelfit.Verdict.Tight _ -> false);
  check "need exceeds budget"
    (starved.Local.Fit.need_bytes > starved.Local.Fit.budget_bytes);
  check "unknown ids have no verdict"
    (Option.is_none (Local.Fit.find ~config:(config gib) "not-a-model"));
  Unix.putenv "SPICE_LOCAL_MEMORY_BUDGET" (string_of_int (8 * gib));
  let from_env =
    expect_fit "env budget"
      (Local.Fit.find ~config:(Local.Config.make ()) "gpt-oss-20b")
  in
  Unix.putenv "SPICE_LOCAL_MEMORY_BUDGET" "";
  equal int ~msg:"env var supplies the default budget" (8 * gib)
    from_env.Local.Fit.budget_bytes

(* Artifact status *)

let with_temp_dir f =
  let dir = Filename.temp_file "spice-local-test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      let rec remove path =
        if Sys.is_directory path then begin
          Array.iter
            (fun entry -> remove (Filename.concat path entry))
            (Sys.readdir path);
          Unix.rmdir path
        end
        else Sys.remove path
      in
      try remove dir with Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f dir)

let expect_status msg = function
  | Ok status -> status
  | Error message -> failf "%s: %s" msg message

let artifact_status () =
  with_temp_dir @@ fun dir ->
  let config = Local.Config.make ~model_dir:dir () in
  (match
     expect_status "missing" (Local.Artifact.status ~config "gpt-oss-20b")
   with
  | Local.Artifact.Missing { path; url; size } ->
      check "missing path is under model_dir"
        (String.starts_with ~prefix:dir path);
      check "missing url is huggingface"
        (String.starts_with ~prefix:"https://huggingface.co/" url);
      check "missing size is exact" (Int64.equal size 12_109_566_560L)
  | Local.Artifact.Installed _ | Local.Artifact.Explicit_path _ ->
      failf "expected Missing for absent artifact");
  let entry =
    match Local.Manifest.find "gpt-oss-20b" with
    | Some entry -> entry
    | None -> failf "gpt-oss-20b not in manifest"
  in
  let file = Filename.concat dir (Local.Manifest.file entry) in
  Out_channel.with_open_bin file (fun oc -> Out_channel.output_string oc "x");
  (match
     expect_status "installed" (Local.Artifact.status ~config "gpt-oss-20b")
   with
  | Local.Artifact.Installed { path } ->
      equal string ~msg:"installed path" file path
  | Local.Artifact.Missing _ | Local.Artifact.Explicit_path _ ->
      failf "expected Installed after touch");
  match
    expect_status "explicit" (Local.Artifact.status ~config "/nope/model.gguf")
  with
  | Local.Artifact.Explicit_path { exists; path } ->
      check "explicit path is echoed" (String.equal path "/nope/model.gguf");
      check "explicit path absent" (not exists)
  | Local.Artifact.Installed _ | Local.Artifact.Missing _ ->
      failf "expected Explicit_path for unknown id"

let artifact_prepare_cancellation () =
  with_temp_dir @@ fun dir ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let config = Local.Config.make ~model_dir:dir () in
  let http =
    Cohttp_eio.Client.make_generic (fun ~sw:_ _ ->
        failwith "unexpected download request")
  in
  match
    Local.Artifact.prepare ~sw ~env ~http
      ~cancelled:(fun () -> true)
      ~config "gpt-oss-20b"
  with
  | Ok () -> failf "expected cancelled prepare"
  | Error error ->
      equal_error_kind "prepare cancellation" Llm.Error.Cancelled error

(* End-to-end against the fake llama-server *)

let fake_server_binary () =
  let path = Filename.concat (Sys.getcwd ()) "bin/fake_llama_server.exe" in
  if Sys.file_exists path then path
  else failf "fake_llama_server.exe not found at %s" path

let with_env bindings f =
  let saved =
    List.map (fun (name, _) -> (name, Sys.getenv_opt name)) bindings
  in
  List.iter (fun (name, value) -> Unix.putenv name value) bindings;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (name, value) ->
          Unix.putenv name (Option.value value ~default:""))
        saved)
    f

let process_exists pid =
  match Unix.kill pid 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

let await_file clock path =
  Eio.Time.with_timeout_exn clock 2. (fun () ->
      while not (Sys.file_exists path) do
        Eio.Time.sleep clock 0.005
      done)

let await_gone clock pid =
  Eio.Time.with_timeout_exn clock 2. (fun () ->
      while process_exists pid do
        Eio.Time.sleep clock 0.005
      done)

let pids path =
  In_channel.with_open_text path In_channel.input_all
  |> String.split_on_char '\n'
  |> List.filter_map (fun value ->
         let value = String.trim value in
         if String.is_empty value then None else int_of_string_opt value)

let one_pid path =
  match pids path with
  | [ pid ] -> pid
  | values ->
      failf "expected one server pid in %s, got %d" path (List.length values)

let chat_sse chunks =
  String.concat ""
    (List.map (fun chunk -> "data: " ^ json_string chunk ^ "\n\n") chunks)
  ^ "data: [DONE]\n\n"

let delta_chunk ?id ?model ?finish_reason ?usage delta =
  let choice =
    [ ("delta", json_object delta) ]
    @ Option.fold ~none:[]
        ~some:(fun reason -> [ ("finish_reason", Json.string reason) ])
        finish_reason
  in
  json_object
    (Option.fold ~none:[] ~some:(fun id -> [ ("id", Json.string id) ]) id
    @ Option.fold ~none:[]
        ~some:(fun model -> [ ("model", Json.string model) ])
        model
    @ [ ("choices", Json.list [ json_object choice ]) ]
    @ Option.fold ~none:[] ~some:(fun usage -> [ ("usage", usage) ]) usage)

let scenario =
  chat_sse
    [
      delta_chunk ~id:"cmpl-1" ~model:"fake-gguf"
        [ ("content", Json.string "Hel") ];
      delta_chunk [ ("content", Json.string "lo") ];
      delta_chunk [ ("reasoning_content", Json.string "pondering") ];
      delta_chunk
        [
          ( "tool_calls",
            Json.list
              [
                json_object
                  [
                    ("index", Json.int 0);
                    ("id", Json.string "call_1");
                    ( "function",
                      json_object
                        [
                          ("name", Json.string "read_file");
                          ("arguments", Json.string {|{"path":|});
                        ] );
                  ];
              ] );
        ];
      delta_chunk
        [
          ( "tool_calls",
            Json.list
              [
                json_object
                  [
                    ("index", Json.int 0);
                    ( "function",
                      json_object [ ("arguments", Json.string {|"x"}|}) ] );
                  ];
              ] );
        ];
      delta_chunk ~finish_reason:"tool_calls" [];
      json_object
        [
          ("choices", Json.list []);
          ( "usage",
            json_object
              [
                ("prompt_tokens", Json.int 10); ("completion_tokens", Json.int 5);
              ] );
        ];
    ]

let with_fake ?(startup_timeout_s = 2.) ?(env = []) f =
  with_temp_dir @@ fun dir ->
  let gguf = Filename.concat dir "lifecycle.gguf" in
  Out_channel.with_open_bin gguf (fun output ->
      Out_channel.output_string output "g");
  let sse_path = Filename.concat dir "lifecycle.sse" in
  Out_channel.with_open_bin sse_path (fun output ->
      Out_channel.output_string output scenario);
  with_env
    (("SPICE_FAKE_LLAMA_SSE", sse_path)
    :: ("SPICE_FAKE_LLAMA_DUMP", "")
    :: env)
  @@ fun () ->
  let config =
    Local.Config.make ~model_dir:dir ~server_binary:(fake_server_binary ())
      ~ctx_size:4096 ~startup_timeout_s ()
  in
  f ~dir ~gguf ~config

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", Json.list [ Json.string "path" ]);
      ("additionalProperties", Json.bool false);
    ]

let read_file_tool = Llm.Tool.make ~name:"read_file" ~input_schema:schema ()

let run_stream ?(cancelled = fun () -> false) client request =
  let events = ref [] in
  let on_event event = events := event :: !events in
  match Llm.Client.response ~cancelled ~on_event client request with
  | Ok response -> Ok (List.rev !events, response)
  | Error error -> Error (List.rev !events, error)

let expect_stream_ok msg = function
  | Ok value -> value
  | Error ((_ : Llm.Stream.Event.t list), error) ->
      failf "%s: %a" msg Llm.Error.pp error

let request ~model_id =
  Llm.Request.make_exn ~model:(Local.model model_id) ~tools:[ read_file_tool ]
    (Llm.Transcript.of_list_exn [ Llm.Message.user_text "hello" ])

let managed_server_round_trip () =
  with_temp_dir @@ fun dir ->
  let gguf = Filename.concat dir "tiny.gguf" in
  Out_channel.with_open_bin gguf (fun oc -> Out_channel.output_string oc "g");
  let sse_path = Filename.concat dir "scenario.sse" in
  Out_channel.with_open_bin sse_path (fun oc ->
      Out_channel.output_string oc scenario);
  let dump_path = Filename.concat dir "request.json" in
  let config =
    Local.Config.make ~model_dir:dir ~server_binary:(fake_server_binary ())
      ~ctx_size:4096 ~startup_timeout_s:20. ()
  in
  with_env
    [
      ("SPICE_FAKE_LLAMA_SSE", sse_path);
      ("SPICE_FAKE_LLAMA_DUMP", dump_path);
    ]
  @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  let events, response =
    expect_stream_ok "round trip" (run_stream client (request ~model_id:gguf))
  in
  let texts =
    List.filter_map
      (function Llm.Stream.Event.Text_delta text -> Some text | _ -> None)
      events
  in
  equal (list string) ~msg:"text deltas" [ "Hel"; "lo" ] texts;
  let reasoning =
    List.filter_map
      (function
        | Llm.Stream.Event.Reasoning_summary_delta text -> Some text | _ -> None)
      events
  in
  equal (list string) ~msg:"reasoning deltas" [ "pondering" ] reasoning;
  equal int ~msg:"tool input deltas" 2
    (List.length
       (List.filter
          (function Llm.Stream.Event.Tool_input_delta _ -> true | _ -> false)
          events));
  equal string ~msg:"assistant text" "Hello" (Llm.Response.text response);
  (match Llm.Response.tool_calls response with
  | [ call ] ->
      equal string ~msg:"call id" "call_1" (Llm.Tool.Call.id call);
      equal string ~msg:"call name" "read_file" (Llm.Tool.Call.name call)
  | calls -> failf "expected one tool call, got %d" (List.length calls));
  equal (option string) ~msg:"response id" (Some "cmpl-1")
    (Llm.Response.response_id response);
  equal (option string) ~msg:"response model" (Some "fake-gguf")
    (Llm.Response.response_model response);
  (match Llm.Response.stop response with
  | Some stop ->
      equal string ~msg:"stop is tool_call"
        (Llm.Response.Stop.label Llm.Response.Stop.tool_call)
        (Llm.Response.Stop.label stop)
  | None -> failf "expected a stop reason");
  (match Llm.Response.usage response with
  | Some usage ->
      equal int ~msg:"usage input" 10 usage.Llm.Usage.input;
      equal int ~msg:"usage output" 5 usage.Llm.Usage.output
  | None -> failf "expected usage");
  (* The encoded request reached the server in chat-completions shape. *)
  let body =
    json_of_string (In_channel.with_open_bin dump_path In_channel.input_all)
  in
  equal string ~msg:"request model is the gguf path" gguf
    (string_field "request" "model" body);
  (match list_field "request" "messages" body with
  | [ message ] ->
      equal string ~msg:"user role" "user"
        (string_field "message" "role" message);
      equal string ~msg:"user content" "hello"
        (string_field "message" "content" message)
  | messages -> failf "expected one message, got %d" (List.length messages));
  (match list_field "request" "tools" body with
  | [ tool ] ->
      let fn =
        match object_field "function" tool with
        | Some fn -> fn
        | None -> failf "tool missing function"
      in
      equal string ~msg:"tool name" "read_file" (string_field "tool" "name" fn)
  | tools -> failf "expected one tool, got %d" (List.length tools));
  (* A second request reuses the resident server. *)
  let _, response2 =
    expect_stream_ok "server reuse" (run_stream client (request ~model_id:gguf))
  in
  equal string ~msg:"second round trip works" "Hello"
    (Llm.Response.text response2)

let owner_switch_reaps_server () =
  with_fake @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "owner.pid" in
  with_env [ ("SPICE_FAKE_LLAMA_PID_FILE", pid_file) ] @@ fun () ->
  let pid =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let client = Local.client ~sw ~env ~config () in
    ignore
      (expect_stream_ok "owner response"
         (run_stream client (request ~model_id:gguf)));
    one_pid pid_file
  in
  check "owner release reaps its server" (not (process_exists pid))

let readiness_result_cancellation_reaps_server () =
  with_fake ~env:[ ("SPICE_FAKE_LLAMA_UNHEALTHY", "1") ]
  @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "cancelled-result.pid" in
  with_env [ ("SPICE_FAKE_LLAMA_PID_FILE", pid_file) ] @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  let cancelled () = Sys.file_exists pid_file in
  (match run_stream ~cancelled client (request ~model_id:gguf) with
  | Ok _ -> failf "expected readiness cancellation"
  | Error (_, error) ->
      equal_error_kind "readiness cancellation" Llm.Error.Cancelled error);
  let pid = one_pid pid_file in
  await_gone (Eio.Stdenv.clock env) pid

let readiness_exception_cancellation_reaps_server () =
  with_fake
    ~env:[ ("SPICE_FAKE_LLAMA_PARTIAL_HEALTH_COUNT", "1") ]
  @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "cancelled-exception.pid" in
  with_env [ ("SPICE_FAKE_LLAMA_PID_FILE", pid_file) ] @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let client = Local.client ~sw ~env ~config () in
  let cancel_context, cancel_context_resolver = Eio.Promise.create () in
  let result =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Eio.Cancel.sub @@ fun context ->
        Eio.Promise.resolve cancel_context_resolver context;
        run_stream client (request ~model_id:gguf))
  in
  await_file clock pid_file;
  Eio.Cancel.cancel
    (Eio.Promise.await cancel_context)
    (Failure "cancel local readiness");
  (match Eio.Promise.await_exn result with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Ok _ -> failf "expected readiness to re-raise cancellation"
  | Error (_, error) ->
      failf "readiness cancellation became an LLM error: %a" Llm.Error.pp
        error);
  await_gone clock (one_pid pid_file)

let failed_readiness_reaps_server () =
  with_fake ~env:[ ("SPICE_FAKE_LLAMA_EXIT_BEFORE_BIND", "1") ]
  @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "early-exit.pid" in
  with_env [ ("SPICE_FAKE_LLAMA_PID_FILE", pid_file) ] @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  (match run_stream client (request ~model_id:gguf) with
  | Ok _ -> failf "expected early server exit"
  | Error (_, error) ->
      check "startup failure reports the server exit"
        (String.includes ~affix:"exited during startup"
           (Llm.Error.message error)));
  await_gone (Eio.Stdenv.clock env) (one_pid pid_file)

let term_ignoring_readiness_is_killed () =
  with_fake ~startup_timeout_s:0.05
    ~env:
      [
        ("SPICE_FAKE_LLAMA_UNHEALTHY", "1");
        ("SPICE_FAKE_LLAMA_IGNORE_TERM", "1");
      ]
  @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "term-ignore.pid" in
  let term_file = Filename.concat dir "term-observed" in
  with_env
    [
      ("SPICE_FAKE_LLAMA_PID_FILE", pid_file);
      ("SPICE_FAKE_LLAMA_TERM_FILE", term_file);
    ]
  @@ fun () ->
  let started = Unix.gettimeofday () in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  (match run_stream client (request ~model_id:gguf) with
  | Ok _ -> failf "expected readiness timeout"
  | Error _ -> ());
  check "SIGTERM reached the server" (Sys.file_exists term_file);
  await_gone (Eio.Stdenv.clock env) (one_pid pid_file);
  check "SIGKILL fallback is bounded" (Unix.gettimeofday () -. started < 2.)

let spontaneous_exit_respawns_in_owner () =
  with_fake ~env:[ ("SPICE_FAKE_LLAMA_EXIT_AFTER_CHAT", "1") ]
  @@ fun ~dir ~gguf ~config ->
  let pid_file = Filename.concat dir "respawn.pids" in
  with_env [ ("SPICE_FAKE_LLAMA_PID_FILE", pid_file) ] @@ fun () ->
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let client = Local.client ~sw ~env ~config () in
  ignore
    (expect_stream_ok "first transient server"
       (run_stream client (request ~model_id:gguf)));
  let first = one_pid pid_file in
  await_gone clock first;
  ignore
    (expect_stream_ok "respawned server"
       (run_stream client (request ~model_id:gguf)));
  match pids pid_file with
  | [ first_pid; second_pid ] ->
      check "spontaneous exit starts a different process"
        (not (Int.equal first_pid second_pid))
  | values -> failf "expected two server starts, got %d" (List.length values)

let health_timeout_releases_the_connection () =
  with_temp_dir @@ fun dir ->
  let gguf = Filename.concat dir "partial-health.gguf" in
  Out_channel.with_open_bin gguf (fun output ->
      Out_channel.output_string output "g");
  let sse_path = Filename.concat dir "partial-health.sse" in
  Out_channel.with_open_bin sse_path (fun output ->
      Out_channel.output_string output scenario);
  let health_dump = Filename.concat dir "health-requests" in
  Unix.putenv "SPICE_FAKE_LLAMA_SSE" sse_path;
  Unix.putenv "SPICE_FAKE_LLAMA_DUMP" "";
  Unix.putenv "SPICE_FAKE_LLAMA_PARTIAL_HEALTH_COUNT" "1";
  Unix.putenv "SPICE_FAKE_LLAMA_HEALTH_DUMP" health_dump;
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "SPICE_FAKE_LLAMA_PARTIAL_HEALTH_COUNT" "";
      Unix.putenv "SPICE_FAKE_LLAMA_HEALTH_DUMP" "")
    (fun () ->
      let config =
        Local.Config.make ~model_dir:dir ~server_binary:(fake_server_binary ())
          ~ctx_size:4096 ~startup_timeout_s:10. ()
      in
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let client = Local.client ~sw ~env ~config () in
      ignore
        (expect_stream_ok "partial health recovers"
           (run_stream client (request ~model_id:gguf))));
  let requests =
    In_channel.with_open_bin health_dump In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.is_empty line))
  in
  equal (list string) ~msg:"health retried after closing the stalled response"
    [ "1"; "2" ] requests

(* Synthetic GGUF weights whose header parses: residency accounting needs a
   known memory estimate per model file. Tiny geometry keeps the estimated
   need near the fixed engine overhead (~1.7 GiB). *)
let write_tiny_gguf path =
  let buf = Buffer.create 512 in
  let u32 v = Buffer.add_int32_le buf (Int32.of_int v) in
  let u64 v = Buffer.add_int64_le buf (Int64.of_int v) in
  let str s =
    u64 (String.length s);
    Buffer.add_string buf s
  in
  let kv_string key v =
    str key;
    u32 8;
    str v
  in
  let kv_u32 key v =
    str key;
    u32 4;
    u32 v
  in
  Buffer.add_string buf "GGUF";
  u32 3;
  u64 0;
  u64 6;
  kv_string "general.architecture" "toy";
  kv_u32 "toy.block_count" 2;
  kv_u32 "toy.context_length" 4096;
  kv_u32 "toy.embedding_length" 128;
  kv_u32 "toy.attention.head_count" 2;
  kv_u32 "toy.attention.head_count_kv" 2;
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc (Buffer.contents buf))

(* Which resident server answered is observable through env inheritance: a
   server keeps dumping to the SPICE_FAKE_LLAMA_DUMP path it was spawned
   with, so a request that lands in a *new* dump file proves a fresh spawn,
   and one that does not proves reuse. *)
let run_tagged ~client ~gguf dump =
  Unix.putenv "SPICE_FAKE_LLAMA_DUMP" dump;
  let _, response =
    expect_stream_ok "tagged run" (run_stream client (request ~model_id:gguf))
  in
  equal string ~msg:"tagged run answers" "Hello" (Llm.Response.text response)

type two_models = {
  dir : string;
  config : Local.Config.t;
  client : Llm.Client.t;
  gguf_a : string;
  gguf_b : string;
}

let with_two_models budget f =
  with_temp_dir @@ fun dir ->
  let gguf_a = Filename.concat dir "model-a.gguf" in
  let gguf_b = Filename.concat dir "model-b.gguf" in
  write_tiny_gguf gguf_a;
  write_tiny_gguf gguf_b;
  let sse_path = Filename.concat dir "scenario.sse" in
  Out_channel.with_open_bin sse_path (fun oc ->
      Out_channel.output_string oc scenario);
  Unix.putenv "SPICE_FAKE_LLAMA_SSE" sse_path;
  let config =
    Local.Config.make ~model_dir:dir ~server_binary:(fake_server_binary ())
      ~ctx_size:4096 ~startup_timeout_s:20. ~memory_budget:budget ()
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  f { dir; config; client; gguf_a; gguf_b }

let co_resident_servers () =
  (* 4 GiB fits two ~1.7 GiB models side by side: the third request must
     reuse model A's server, not respawn it. *)
  with_two_models (4 * gib) @@ fun { dir; config; client; gguf_a; gguf_b } ->
  run_tagged ~client ~gguf:gguf_a (Filename.concat dir "dump_a");
  run_tagged ~client ~gguf:gguf_b (Filename.concat dir "dump_b");
  Unix.putenv "SPICE_FAKE_LLAMA_DUMP" (Filename.concat dir "dump_c");
  let _, response =
    expect_stream_ok "reuse" (run_stream client (request ~model_id:gguf_a))
  in
  equal string ~msg:"reused server answers" "Hello" (Llm.Response.text response);
  check "model A's server was reused, not respawned"
    (not (Sys.file_exists (Filename.concat dir "dump_c")));
  (* Explicit paths also get fit verdicts, from the file's own header. *)
  match Local.Fit.find ~config gguf_a with
  | Some fit ->
      check "explicit path fits"
        (match fit.Local.Fit.verdict with
        | Spice_modelfit.Verdict.Fits -> true
        | Spice_modelfit.Verdict.Tight _ | Spice_modelfit.Verdict.Wont_run ->
            false)
  | None -> failf "expected a fit verdict for an explicit gguf path"

let eviction_under_budget () =
  (* 2 GiB holds one ~1.7 GiB model: admitting B evicts A, so a later A
     request must spawn a fresh server. *)
  with_two_models (2 * gib) @@ fun setup ->
  run_tagged ~client:setup.client ~gguf:setup.gguf_a
    (Filename.concat setup.dir "dump_d");
  run_tagged ~client:setup.client ~gguf:setup.gguf_b
    (Filename.concat setup.dir "dump_e");
  run_tagged ~client:setup.client ~gguf:setup.gguf_a
    (Filename.concat setup.dir "dump_f");
  check "model A was evicted and respawned"
    (Sys.file_exists (Filename.concat setup.dir "dump_f"))

let missing_binary_is_reported () =
  with_temp_dir @@ fun dir ->
  let gguf = Filename.concat dir "tiny2.gguf" in
  Out_channel.with_open_bin gguf (fun oc -> Out_channel.output_string oc "g");
  let config =
    Local.Config.make ~model_dir:dir
      ~server_binary:"spice-test-no-such-llama-server" ()
  in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Local.client ~sw ~env ~config () in
  match run_stream client (request ~model_id:gguf) with
  | Ok _ -> failf "expected a missing-binary error"
  | Error ((_ : Llm.Stream.Event.t list), error) ->
      check "error names PATH resolution"
        (String.includes ~affix:"not found on PATH" (Llm.Error.message error))

let () =
  run "spice.llm.local"
    [
      test "manifest integrity" manifest_integrity;
      test "model and config contracts" model_contracts;
      test "fit verdicts" fit_verdicts;
      test "artifact status" artifact_status;
      test "artifact prepare cancellation" artifact_prepare_cancellation;
      test "managed server round trip" managed_server_round_trip;
      test ~timeout:3. "owner switch reaps managed server"
        owner_switch_reaps_server;
      test ~timeout:3. "readiness result cancellation reaps server"
        readiness_result_cancellation_reaps_server;
      test ~timeout:3. "readiness exception cancellation reaps server"
        readiness_exception_cancellation_reaps_server;
      test ~timeout:3. "failed readiness reaps server"
        failed_readiness_reaps_server;
      test ~timeout:3. "TERM-ignoring readiness is killed"
        term_ignoring_readiness_is_killed;
      test ~timeout:3. "spontaneous server exit respawns within its owner"
        spontaneous_exit_respawns_in_owner;
      test ~timeout:6. "health timeout releases the stalled connection"
        health_timeout_releases_the_connection;
      test "co-resident servers within budget" co_resident_servers;
      test "eviction under a tight budget" eviction_under_budget;
      test "missing binary is reported" missing_binary_is_reported;
    ]
