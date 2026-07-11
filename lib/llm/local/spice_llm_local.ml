(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Llm = Spice_llm
module Options = Llm.Request.Options

let log_src = Logs.Src.create "spice.llm.local" ~doc:"Managed local provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let ( let* ) = Result.bind
let provider = Llm.Provider.make "local"
let api = Llm.Model.Api.make "chat-completions"
let model id = Llm.Model.make ~provider ~api ~id
let invalid fn message = invalid_arg ("Spice_llm_local." ^ fn ^ ": " ^ message)

let check_path fn name = function
  | None -> ()
  | Some value ->
      if String.is_empty value then invalid fn (name ^ " must not be empty")

let check_positive fn name value =
  if value <= 0 then invalid fn (name ^ " must be positive")

module Config = struct
  type t = {
    model_dir : string option;
    server_binary : string option;
    ctx_size : int;
    startup_timeout_s : float;
    memory_budget : int option;
  }

  let env_memory_budget () =
    match Sys.getenv_opt "SPICE_LOCAL_MEMORY_BUDGET" with
    | None -> None
    | Some value -> (
        match int_of_string_opt (String.trim value) with
        | Some bytes when bytes > 0 -> Some bytes
        | Some _ | None -> None)

  let env_server_binary () =
    match Sys.getenv_opt "SPICE_LOCAL_SERVER_BINARY" with
    | None -> None
    | Some value -> (
        match String.trim value with "" -> None | binary -> Some binary)

  let make ?model_dir ?server_binary ?(ctx_size = 32768)
      ?(startup_timeout_s = 300.) ?memory_budget () =
    check_path "Config.make" "model_dir" model_dir;
    check_path "Config.make" "server_binary" server_binary;
    check_positive "Config.make" "ctx_size" ctx_size;
    if (not (Float.is_finite startup_timeout_s)) || startup_timeout_s <= 0. then
      invalid "Config.make" "startup_timeout_s must be positive and finite";
    Option.iter (check_positive "Config.make" "memory_budget") memory_budget;
    let memory_budget =
      match memory_budget with
      | Some _ as budget -> budget
      | None -> env_memory_budget ()
    in
    let server_binary =
      match server_binary with
      | Some _ as binary -> binary
      | None -> env_server_binary ()
    in
    { model_dir; server_binary; ctx_size; startup_timeout_s; memory_budget }

  let default = make ()
end

module Manifest = struct
  type entry = {
    id : string;
    display_name : string;
    family : string;
    repo : string;
    file : string;
    size : int64;
    sha256 : string;
    context_length : int;
    reasoning : bool;
    (* Memory-guard inputs. [kv_layers] counts KV-bearing layers only:
       hybrid-attention models cache KV for a subset of their layers. *)
    kv_layers : int;
    n_kv_heads : int;
    head_dim : int;
  }

  (* Facts verified against the Hugging Face API (file size and LFS SHA-256)
     and each model's published config.json (attention geometry) on
     2026-07-05. *)
  let all =
    [
      {
        id = "qwen3-coder-30b";
        display_name = "Qwen3 Coder 30B (Q4_K_M)";
        family = "qwen3-coder";
        repo = "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF";
        file = "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf";
        size = 18_556_689_568L;
        sha256 =
          "fadc3e5f8d42bf7e894a785b05082e47daee4df26680389817e2093056f088ad";
        context_length = 262_144;
        reasoning = false;
        kv_layers = 48;
        n_kv_heads = 4;
        head_dim = 128;
      };
      {
        id = "gpt-oss-20b";
        display_name = "gpt-oss 20B (MXFP4)";
        family = "gpt-oss";
        repo = "ggml-org/gpt-oss-20b-GGUF";
        file = "gpt-oss-20b-mxfp4.gguf";
        size = 12_109_566_560L;
        sha256 =
          "be37a636aca0fc1aae0d32325f82f6b4d21495f06823b5fbc1898ae0303e9935";
        context_length = 131_072;
        reasoning = true;
        kv_layers = 24;
        n_kv_heads = 8;
        head_dim = 64;
      };
      {
        id = "devstral-small-2";
        display_name = "Devstral Small 2 24B (Q4_K_M)";
        family = "devstral";
        repo = "unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF";
        file = "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf";
        size = 14_334_446_752L;
        sha256 =
          "d14ba9edee1bb4c4996a726deb81e49ae81800a3216f0774634238c380aee496";
        context_length = 393_216;
        reasoning = false;
        kv_layers = 40;
        n_kv_heads = 8;
        head_dim = 128;
      };
      {
        id = "qwen3.6-35b";
        display_name = "Qwen3.6 35B (Q4_K_M)";
        family = "qwen3.6";
        repo = "unsloth/Qwen3.6-35B-A3B-GGUF";
        file = "Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
        size = 22_134_528_992L;
        sha256 =
          "ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61";
        context_length = 262_144;
        reasoning = true;
        (* Hybrid attention: 10 of 40 layers are full attention; the linear
           layers keep constant-size state, not a KV cache. *)
        kv_layers = 10;
        n_kv_heads = 2;
        head_dim = 256;
      };
    ]

  let find id = List.find_opt (fun entry -> String.equal entry.id id) all
  let id entry = entry.id
  let display_name entry = entry.display_name
  let family entry = entry.family
  let file entry = entry.file

  let url entry =
    "https://huggingface.co/" ^ entry.repo ^ "/resolve/main/"
    ^ Uri.pct_encode entry.file

  let size entry = entry.size
  let context_length entry = entry.context_length
  let reasoning entry = entry.reasoning

  let fit entry =
    Spice_modelfit.Model.make ~weights_bytes:(Int64.to_int entry.size)
      ~n_kv_layers:entry.kv_layers ~n_kv_heads:entry.n_kv_heads
      ~head_dim:entry.head_dim ~max_context:entry.context_length
end

let llm_error ?(phase = Llm.Error.Startup) ?status kind message =
  Llm.Error.make ~kind ~phase ~provider ?status message

let unsupported message = Error (llm_error Llm.Error.Unsupported message)

let startup_provider_error message =
  Error (llm_error Llm.Error.Provider message)

let stream_error kind message = llm_error ~phase:Llm.Error.Stream kind message

let cancelled_error ?(phase = Llm.Error.Startup) () =
  llm_error ~phase Llm.Error.Cancelled "local request cancelled"

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
      Result.map
        (fun dir -> dir / "spice" / "models")
        (default_xdg_dir "XDG_DATA_HOME" ~home_suffix:(".local" / "share"))

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

type artifact_status =
  | Installed of { path : string }
  | Missing of { path : string; url : string; size : int64 }
  | Explicit_path of { path : string; exists : bool }

let artifact_status ?(config = Config.default) id =
  match model_dir config.Config.model_dir with
  | Error message -> Error message
  | Ok dir -> (
      match Manifest.find id with
      | Some entry ->
          let path = Filename.concat dir entry.Manifest.file in
          if Sys.file_exists path then Ok (Installed { path })
          else
            Ok
              (Missing
                 { path; url = Manifest.url entry; size = entry.Manifest.size })
      | None -> Ok (Explicit_path { path = id; exists = Sys.file_exists id }))

let pp_bytes ppf bytes =
  let gib = 1024. *. 1024. *. 1024. in
  Format.fprintf ppf "%.1f GiB" (Int64.to_float bytes /. gib)

let format_bytes bytes = Format.asprintf "%a" pp_bytes bytes

let budget_for config =
  match config.Config.memory_budget with
  | Some budget -> Some budget
  | None ->
      Option.map Spice_modelfit.Machine.budget
        (Spice_modelfit.Machine.detect ())

(* Guard inputs for an explicit GGUF path, read from the file's own header.
   GGUF metadata precedes tensor data, so a short prefix usually suffices;
   grow it on [Truncated] up to a cap. [None] when the header cannot be
   parsed — the caller then treats the model's memory need as unknown. *)
let gguf_fit_of_path path =
  match Unix.stat path with
  | exception Unix.Unix_error _ -> None
  | { Unix.st_size; _ } ->
      let read_prefix length =
        In_channel.with_open_bin path (fun ic ->
            really_input_string ic (Int.min length st_size))
      in
      let max_prefix = 33_554_432 in
      let rec attempt length =
        match read_prefix length with
        | exception (Sys_error _ | End_of_file) -> None
        | prefix -> (
            match Spice_modelfit.Gguf.of_prefix prefix with
            | Ok gguf -> (
                match Spice_modelfit.Gguf.model ~weights_bytes:st_size gguf with
                | Ok fit -> Some fit
                | Error reason ->
                    Log.debug (fun m ->
                        m "gguf header of %s has no guard inputs: %a" path
                          Spice_modelfit.Gguf.Model_error.pp reason);
                    None)
            | Error Spice_modelfit.Gguf.Error.Truncated
              when length < max_prefix && length < st_size ->
                attempt (length * 4)
            | Error error ->
                Log.debug (fun m ->
                    m "gguf header of %s: %a" path Spice_modelfit.Gguf.Error.pp
                      error);
                None)
      in
      attempt 524_288

module Fit = struct
  type t = {
    verdict : Spice_modelfit.Verdict.t;
    need_bytes : int;
    budget_bytes : int;
  }

  let of_inputs ~budget inputs =
    let verdict = Spice_modelfit.verdict ~budget inputs in
    let decisive_context =
      match verdict with
      | Spice_modelfit.Verdict.Wont_run -> Spice_modelfit.min_useful_context
      | Spice_modelfit.Verdict.Fits | Spice_modelfit.Verdict.Tight _ ->
          Spice_modelfit.default_context
    in
    let need_bytes =
      Spice_modelfit.Estimate.total_bytes
        (Spice_modelfit.estimate ~context:decisive_context inputs)
    in
    { verdict; need_bytes; budget_bytes = budget }

  let of_entry ~budget entry = of_inputs ~budget (Manifest.fit entry)

  let find ?(config = Config.default) id =
    let inputs =
      match Manifest.find id with
      | Some entry -> Some (Manifest.fit entry)
      | None ->
          if String.ends_with ~suffix:".gguf" id && Sys.file_exists id then
            gguf_fit_of_path id
          else None
    in
    match inputs with
    | None -> None
    | Some inputs ->
        Option.map (fun budget -> of_inputs ~budget inputs) (budget_for config)

  let to_string t =
    let bytes value = format_bytes (Int64.of_int value) in
    match t.verdict with
    | Spice_modelfit.Verdict.Fits ->
        Printf.sprintf "fits (~%s of %s)" (bytes t.need_bytes)
          (bytes t.budget_bytes)
    | Spice_modelfit.Verdict.Tight { max_context } ->
        Printf.sprintf "fits up to ~%dk context" (max_context / 1024)
    | Spice_modelfit.Verdict.Wont_run ->
        Printf.sprintf "needs ~%s, %s usable" (bytes t.need_bytes)
          (bytes t.budget_bytes)

  let pp ppf t = Format.pp_print_string ppf (to_string t)
end

(* The download guard: refuse to download a model this machine cannot load
   even at the minimum useful context. Loads are never hard-blocked; hours of
   downloading are. *)
let guard_download ~config ~force entry =
  if force then Ok ()
  else
    match budget_for config with
    | None -> Ok ()
    | Some budget -> (
        let fit = Fit.of_entry ~budget entry in
        match fit.Fit.verdict with
        | Spice_modelfit.Verdict.Fits | Spice_modelfit.Verdict.Tight _ -> Ok ()
        | Spice_modelfit.Verdict.Wont_run ->
            unsupported
              (Printf.sprintf
                 "local model %S needs an estimated %s of memory even at a \
                  %d-token context; this machine's usable budget is %s. It \
                  would download (%s) but never load. Override the guard to \
                  download anyway."
                 entry.Manifest.id
                 (format_bytes (Int64.of_int fit.Fit.need_bytes))
                 Spice_modelfit.min_useful_context
                 (format_bytes (Int64.of_int budget))
                 (format_bytes entry.Manifest.size)))

let emit_download ~observe_download progress =
  Option.iter (fun observe -> observe progress) observe_download

let download_progress ~observe_download ~model ~label ~path ~received ~total
    ~phase =
  emit_download ~observe_download
    { Download.model; label; path; received; total; phase }

let download_artifact ~env ~http ~cancelled ?observe_download entry ~path =
  let id = entry.Manifest.id in
  let label = entry.Manifest.file in
  let size = entry.Manifest.size in
  Log.info (fun m -> m "downloading model=%s size=%Ld" id size);
  let observe phase ~received ~total =
    let phase =
      match phase with
      | Spice_llm_artifact.Checking -> Download.Checking
      | Spice_llm_artifact.Downloading -> Download.Downloading
      | Spice_llm_artifact.Verifying -> Download.Verifying
      | Spice_llm_artifact.Installed -> Download.Installed
    in
    download_progress ~observe_download ~model:id ~label ~path ~received ~total
      ~phase
  in
  let* () =
    Spice_llm_artifact.install ~env ~http ~provider ~cancelled ~observe
      ~url:(Manifest.url entry) ~path ~size ~sha256:entry.Manifest.sha256
  in
  Log.info (fun m -> m "model installed model=%s path=%s" id path);
  Ok path

let ensure_model_path ?http ?observe_download ?(force = false) ~sw ~env
    ~cancelled config id =
  Eio.Switch.check sw;
  let* () = if cancelled () then Error (cancelled_error ()) else Ok () in
  match model_dir config.Config.model_dir with
  | Error message -> startup_provider_error message
  | Ok dir -> (
      match Manifest.find id with
      | Some entry -> (
          let path = Filename.concat dir entry.Manifest.file in
          if Sys.file_exists path then Ok path
          else
            match http with
            | None ->
                startup_provider_error
                  (Printf.sprintf
                     "local model %S is not downloaded at %s and automatic \
                      download is unavailable"
                     id path)
            | Some http ->
                let* () = guard_download ~config ~force entry in
                download_artifact ~env ~http ~cancelled ?observe_download entry
                  ~path)
      | None ->
          if Sys.file_exists id then Ok id
          else
            startup_provider_error
              (Printf.sprintf "local model path does not exist: %s" id))

module Artifact = struct
  type status = artifact_status =
    | Installed of { path : string }
    | Missing of { path : string; url : string; size : int64 }
    | Explicit_path of { path : string; exists : bool }

  let status = artifact_status

  let prepare ~sw ~env ~http ~cancelled ?observe_download
      ?(config = Config.default) ?force id =
    Result.map
      (fun (_ : string) -> ())
      (ensure_model_path ~http ?observe_download ?force ~sw ~env ~cancelled
         config id)
end

(* One managed server per process. The resident server intentionally
   outlives client values: a client is rebuilt per turn, and reloading a
   multi-gigabyte model per turn would be unusable. This is process-owned
   runtime state, torn down at exit or when a different model is
   requested. *)
module Server = struct
  type t = {
    model_path : string;
    ctx : int;
    port : int;
    pid : int;
    need_bytes : int option;
        (* Estimated memory need; [None] when the GGUF header could not be
           read, in which case the server gets exclusive residency. *)
    mutable last_used : int; (* Monotonic tick for LRU eviction. *)
  }

  let residents : t list ref = ref []
  let use_clock = ref 0
  let mutex = Eio.Mutex.create ()
  let cleanup_installed = ref false

  let touch t =
    incr use_clock;
    t.last_used <- !use_clock

  let install_cleanup () =
    if not !cleanup_installed then begin
      cleanup_installed := true;
      at_exit (fun () ->
          List.iter
            (fun t ->
              try Unix.kill t.pid Sys.sigterm with Unix.Unix_error _ -> ())
            !residents)
    end

  let alive t =
    match Unix.waitpid [ Unix.WNOHANG ] t.pid with
    | 0, _ -> true
    | _ -> false
    | exception Unix.Unix_error _ -> false

  let base_url t = Printf.sprintf "http://127.0.0.1:%d" t.port

  let free_port () =
    let sock = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close sock)
      (fun () ->
        Unix.bind sock (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
        match Unix.getsockname sock with
        | Unix.ADDR_INET (_, port) -> port
        | Unix.ADDR_UNIX _ -> assert false)

  let find_binary = function
    | Some binary when String.contains binary '/' ->
        if Sys.file_exists binary then Ok binary
        else Error (Printf.sprintf "llama-server binary not found at %s" binary)
    | spec -> (
        let name = Option.value spec ~default:"llama-server" in
        let path = Option.value (Sys.getenv_opt "PATH") ~default:"" in
        let candidate dir =
          if String.is_empty dir then None
          else
            let candidate = Filename.concat dir name in
            if Sys.file_exists candidate then Some candidate else None
        in
        match List.find_map candidate (String.split_on_char ':' path) with
        | Some binary -> Ok binary
        | None ->
            Error
              (name
             ^ " was not found on PATH; install llama.cpp (for example: brew \
                install llama.cpp) or configure an explicit server binary"))

  let stop ~clock t =
    Log.info (fun m -> m "stopping llama-server pid=%d" t.pid);
    (try Unix.kill t.pid Sys.sigterm with Unix.Unix_error _ -> ());
    let deadline = Eio.Time.now clock +. 5.0 in
    let rec wait () =
      if alive t then
        if Eio.Time.now clock >= deadline then begin
          (try Unix.kill t.pid Sys.sigkill with Unix.Unix_error _ -> ());
          try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ()
        end
        else begin
          Eio.Time.sleep clock 0.05;
          wait ()
        end
    in
    wait ()

  let start ~config ~model_path ~ctx ~need_bytes =
    let* binary = find_binary config.Config.server_binary in
    let port = free_port () in
    let argv =
      [|
        binary;
        "-m";
        model_path;
        "--host";
        "127.0.0.1";
        "--port";
        string_of_int port;
        "-c";
        string_of_int ctx;
        "--jinja";
      |]
    in
    let null_in = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
    let null_out = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
    let close_fds () =
      (try Unix.close null_in with Unix.Unix_error _ -> ());
      try Unix.close null_out with Unix.Unix_error _ -> ()
    in
    match Unix.create_process binary argv null_in null_out null_out with
    | pid ->
        close_fds ();
        Log.info (fun m ->
            m "started llama-server pid=%d port=%d model=%s ctx=%d" pid port
              model_path ctx);
        Ok { model_path; ctx; port; pid; need_bytes; last_used = 0 }
    | exception Unix.Unix_error (code, _, _) ->
        close_fds ();
        Error
          (Printf.sprintf "failed to start %s: %s" binary
             (Unix.error_message code))

  let wait_healthy ~sw ~env ~cancelled ~config t =
    let clock = Eio.Stdenv.clock env in
    let api_client = Api.Client.make ~base_url:(base_url t) ~sw ~env () in
    let deadline = Eio.Time.now clock +. config.Config.startup_timeout_s in
    let rec poll () =
      if cancelled () then Error "local server startup cancelled"
      else if not (alive t) then
        Error
          "llama-server exited during startup; run it by hand to see why (it \
           may be out of memory or the GGUF may be unsupported)"
      else
        match Api.health api_client with
        | Ok () -> Ok ()
        | Error _ ->
            if Eio.Time.now clock >= deadline then
              Error
                (Printf.sprintf
                   "llama-server did not become healthy within %.0fs"
                   config.Config.startup_timeout_s)
            else begin
              Eio.Time.sleep clock 0.5;
              poll ()
            end
    in
    poll ()

  let evict ~clock ~admitting victim =
    Log.warn (fun m ->
        m
          "evicting llama-server for %s to make room for %s; alternating \
           between these models reloads weights every switch (consider a \
           hosted small model or a larger memory budget)"
          victim.model_path admitting);
    stop ~clock victim;
    residents :=
      List.filter (fun t -> not (Int.equal t.pid victim.pid)) !residents

  let lru () =
    match !residents with
    | [] -> None
    | first :: rest ->
        Some
          (List.fold_left
             (fun oldest t ->
               if t.last_used < oldest.last_used then t else oldest)
             first rest)

  (* Admission: keep every resident whose need is known while the sum fits
     the budget; evict least-recently-used otherwise. Servers with unknown
     needs cannot be accounted for, so they neither share residency with
     others nor survive a new admission. *)
  let make_room ~clock ~budget ~model_path ~need_bytes =
    let over () =
      match (budget, need_bytes) with
      | None, _ | _, None -> not (List.is_empty !residents)
      | Some budget, Some need ->
          List.exists (fun t -> Option.is_none t.need_bytes) !residents
          || List.fold_left
               (fun sum t -> sum + Option.value t.need_bytes ~default:0)
               need !residents
             > budget
    in
    let rec loop () =
      if over () then
        match lru () with
        | None -> ()
        | Some victim ->
            evict ~clock ~admitting:model_path victim;
            loop ()
    in
    loop ()

  let ensure ~sw ~env ~cancelled ~config ~model_path ~ctx ~need_bytes ~budget =
    Eio.Mutex.use_rw ~protect:false mutex (fun () ->
        install_cleanup ();
        let clock = Eio.Stdenv.clock env in
        residents := List.filter alive !residents;
        match
          List.find_opt
            (fun t ->
              String.equal t.model_path model_path && Int.equal t.ctx ctx)
            !residents
        with
        | Some t ->
            touch t;
            Ok t
        | None -> (
            (* A same-model server with a different context is stale. *)
            List.iter
              (evict ~clock ~admitting:model_path)
              (List.filter
                 (fun t -> String.equal t.model_path model_path)
                 !residents);
            make_room ~clock ~budget ~model_path ~need_bytes;
            let* t = start ~config ~model_path ~ctx ~need_bytes in
            residents := t :: !residents;
            touch t;
            match wait_healthy ~sw ~env ~cancelled ~config t with
            | Ok () ->
                Log.info (fun m ->
                    m "llama-server ready pid=%d port=%d model=%s" t.pid t.port
                      t.model_path);
                Ok t
            | Error message ->
                stop ~clock t;
                residents :=
                  List.filter (fun r -> not (Int.equal r.pid t.pid)) !residents;
                Error message))
end

(* Request encoding: provider-neutral messages to chat-completions JSON. *)

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let list_member name value = json_member name (Jsont.Json.list value)

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> value
  | Error message -> invalid "json_string" ("JSON encode failed: " ^ message)

let json_of_string text =
  match Jsont_bytesrw.decode_string Jsont.json text with
  | Ok _ as ok -> ok
  | Error message -> Error message

let text_of_content ~what blocks =
  let rec loop acc = function
    | [] -> Ok (String.concat "\n" (List.rev acc))
    | Llm.Content.Text text :: rest -> loop (text :: acc) rest
    | Llm.Content.Media _ :: _ ->
        unsupported ("local models support text " ^ what ^ " only")
  in
  loop [] blocks

let role_message role content =
  Jsont.Json.object'
    [ string_member "role" role; string_member "content" content ]

let encode_assistant assistant =
  let texts, calls =
    List.fold_left
      (fun (texts, calls) part ->
        match part with
        | Llm.Message.Assistant.Text text -> (text :: texts, calls)
        | Llm.Message.Assistant.Tool_call call -> (texts, call :: calls)
        | Llm.Message.Assistant.Reasoning _ ->
            (* Reasoning is not replayable over chat completions; models
               re-derive it. *)
            (texts, calls))
      ([], [])
      (Llm.Message.Assistant.parts assistant)
  in
  let texts = List.rev texts and calls = List.rev calls in
  if List.is_empty texts && List.is_empty calls then []
  else
    let encode_call call =
      Jsont.Json.object'
        [
          string_member "id" (Llm.Tool.Call.id call);
          string_member "type" "function";
          json_member "function"
            (Jsont.Json.object'
               [
                 string_member "name" (Llm.Tool.Call.name call);
                 string_member "arguments"
                   (json_string (Llm.Tool.Call.input call));
               ]);
        ]
    in
    let fields = [ string_member "role" "assistant" ] in
    let fields =
      match texts with
      | [] -> fields
      | texts -> string_member "content" (String.concat "\n" texts) :: fields
    in
    let fields =
      match calls with
      | [] -> fields
      | calls -> list_member "tool_calls" (List.map encode_call calls) :: fields
    in
    [ Jsont.Json.object' (List.rev fields) ]

let encode_message = function
  | Llm.Message.System text | Llm.Message.Developer text ->
      (* Local chat templates know [system]; [developer] is an OpenAI-ism. *)
      Ok [ role_message "system" text ]
  | Llm.Message.User content ->
      let* text = text_of_content ~what:"user content" content in
      Ok [ role_message "user" text ]
  | Llm.Message.Assistant assistant -> Ok (encode_assistant assistant)
  | Llm.Message.Tool_result result ->
      let* text =
        text_of_content ~what:"tool results" (Llm.Tool.Result.content result)
      in
      Ok
        [
          Jsont.Json.object'
            [
              string_member "role" "tool";
              string_member "tool_call_id" (Llm.Tool.Result.call_id result);
              string_member "content" text;
            ];
        ]

let encode_tool tool =
  let fields =
    [
      string_member "name" (Llm.Tool.name tool);
      json_member "parameters" (Llm.Tool.input_schema tool);
    ]
  in
  let fields =
    match Llm.Tool.description tool with
    | None -> fields
    | Some description -> string_member "description" description :: fields
  in
  Jsont.Json.object'
    [
      string_member "type" "function";
      json_member "function" (Jsont.Json.object' (List.rev fields));
    ]

let encode_tool_choice = function
  | Options.Auto -> None
  | Options.No_tools -> Some (Jsont.Json.string "none")
  | Options.Required -> Some (Jsont.Json.string "required")
  | Options.Tool name ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "function";
             json_member "function"
               (Jsont.Json.object' [ string_member "name" name ]);
           ])

let encode_response_format = function
  | Options.Text -> None
  | Options.Json_schema { name; schema; strict } ->
      Some
        (Jsont.Json.object'
           [
             string_member "type" "json_schema";
             json_member "json_schema"
               (Jsont.Json.object'
                  [
                    string_member "name" name;
                    json_member "schema" schema;
                    bool_member "strict" strict;
                  ]);
           ])

let encode_reasoning_effort = function
  | None | Some Options.Reasoning_effort.Disabled -> Ok None
  | Some Options.Reasoning_effort.Low -> Ok (Some "low")
  | Some Options.Reasoning_effort.Medium -> Ok (Some "medium")
  | Some Options.Reasoning_effort.High -> Ok (Some "high")
  | Some
      ( Options.Reasoning_effort.Minimal | Options.Reasoning_effort.Extra_high
      | Options.Reasoning_effort.Max ) ->
      unsupported "local models support reasoning effort low, medium, or high"

let result_map f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest -> (
        match f value with
        | Ok mapped -> loop (mapped :: acc) rest
        | Error _ as error -> error)
  in
  loop [] values

let encode_request request =
  let model = Llm.Request.model request in
  if not (Llm.Model.Api.equal (Llm.Model.api model) api) then
    unsupported
      ("local provider does not support model API: "
      ^ Llm.Model.Api.id (Llm.Model.api model))
  else
    let options = Llm.Request.options request in
    let* messages_nested =
      result_map encode_message (Llm.Request.messages request)
    in
    let* reasoning_effort =
      encode_reasoning_effort (Options.reasoning_effort options)
    in
    Ok
      {
        Api.Chat.model = Llm.Model.id model;
        messages = List.concat messages_nested;
        tools = List.map encode_tool (Llm.Request.tools request);
        tool_choice = encode_tool_choice (Options.tool_choice options);
        response_format =
          encode_response_format (Options.response_format options);
        reasoning_effort;
        max_tokens = Options.max_output_tokens options;
        temperature = Options.temperature options;
      }

(* Stream decoding: chat-completions chunks to provider-neutral events. *)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Jsont.Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some _ | None -> None

let int_field name json =
  match object_field name json with
  | Some (Jsont.Number (value, _)) when Float.is_integer value ->
      Some (Float.to_int value)
  | Some _ | None -> None

let list_field name json =
  match object_field name json with
  | Some (Jsont.Array (values, _)) -> Some values
  | Some _ | None -> None

let usage_of_json json =
  let prompt = Option.value (int_field "prompt_tokens" json) ~default:0 in
  let completion =
    Option.value (int_field "completion_tokens" json) ~default:0
  in
  let cache_read =
    match object_field "prompt_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "cached_tokens" details) ~default:0
  in
  let reasoning =
    match object_field "completion_tokens_details" json with
    | None -> 0
    | Some details ->
        Option.value (int_field "reasoning_tokens" details) ~default:0
  in
  let input = max 0 (prompt - cache_read) in
  let output = max 0 (completion - reasoning) in
  Llm.Usage.make ~input ~output ~reasoning ~cache_read ()

let api_error ?(phase = Llm.Error.Startup) = function
  | Api.Error.Transport message -> llm_error ~phase Llm.Error.Transport message
  | Api.Error.Decode message -> llm_error ~phase Llm.Error.Decode message
  | Api.Error.Response response ->
      let kind =
        match response.Api.Error.status with
        | 400 -> Llm.Error.Invalid_request
        | 413 -> Llm.Error.Context_overflow
        | status when status >= 500 -> Llm.Error.Provider
        | _ -> Llm.Error.Provider
      in
      let message =
        match
          Jsont_bytesrw.decode_string Jsont.json response.Api.Error.body
        with
        | Ok json -> (
            match object_field "error" json with
            | Some error_json ->
                Option.value
                  (string_field "message" error_json)
                  ~default:"local server request failed"
            | None ->
                Option.value
                  (string_field "message" json)
                  ~default:"local server request failed")
        | Error _ -> "local server request failed"
      in
      llm_error ~phase ~status:response.Api.Error.status kind message

type partial = {
  mutable call_id : string option;
  mutable name : string option;
  input : Buffer.t;
}

let stream_events ~cancelled requested_model api_stream =
  let partials : (int, partial) Hashtbl.t = Hashtbl.create 4 in
  let call_order = ref [] in
  let content = Buffer.create 256 in
  let reasoning = Buffer.create 256 in
  let finish_reason = ref None in
  let response_model = ref None in
  let response_id = ref None in
  let usage = ref None in
  let pending = Queue.create () in
  let terminal = ref false in
  let emit item = Queue.add item pending in
  let fail error =
    terminal := true;
    emit (Llm.Stream.Failed error)
  in
  let partial_at index =
    match Hashtbl.find_opt partials index with
    | Some partial -> partial
    | None ->
        let partial =
          { call_id = None; name = None; input = Buffer.create 64 }
        in
        Hashtbl.add partials index partial;
        call_order := index :: !call_order;
        partial
  in
  let record_ids json =
    (match (!response_model, string_field "model" json) with
    | None, (Some _ as value) -> response_model := value
    | _ -> ());
    match (!response_id, string_field "id" json) with
    | None, (Some _ as value) -> response_id := value
    | _ -> ()
  in
  let handle_tool_call_delta json =
    let index = Option.value (int_field "index" json) ~default:0 in
    let partial = partial_at index in
    (match string_field "id" json with
    | Some id when not (String.is_empty id) -> partial.call_id <- Some id
    | Some _ | None -> ());
    match object_field "function" json with
    | None -> ()
    | Some fn -> (
        (match string_field "name" fn with
        | Some name when not (String.is_empty name) -> partial.name <- Some name
        | Some _ | None -> ());
        match string_field "arguments" fn with
        | Some delta when not (String.is_empty delta) ->
            Buffer.add_string partial.input delta;
            emit
              (Llm.Stream.Event
                 (Llm.Stream.Event.tool_input_delta
                    (Llm.Stream.Event.Tool_input.make ~key:(string_of_int index)
                       ?call_id:partial.call_id ?name:partial.name
                       ~input_delta:delta ())))
        | Some _ | None -> ())
  in
  let handle_delta delta =
    (match string_field "content" delta with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string content text;
        emit (Llm.Stream.Event (Llm.Stream.Event.text_delta text))
    | Some _ | None -> ());
    (match
       match string_field "reasoning_content" delta with
       | Some _ as value -> value
       | None -> string_field "reasoning" delta
     with
    | Some text when not (String.is_empty text) ->
        Buffer.add_string reasoning text;
        emit (Llm.Stream.Event (Llm.Stream.Event.reasoning_summary_delta text))
    | Some _ | None -> ());
    match list_field "tool_calls" delta with
    | None -> ()
    | Some calls -> List.iter handle_tool_call_delta calls
  in
  let handle_chunk json =
    record_ids json;
    (match object_field "usage" json with
    | Some (Jsont.Object _ as usage_json) ->
        let value = usage_of_json usage_json in
        usage := Some value;
        emit (Llm.Stream.Event (Llm.Stream.Event.usage value))
    | Some _ | None -> ());
    match list_field "choices" json with
    | None | Some [] -> ()
    | Some (choice :: _) -> (
        (match string_field "finish_reason" choice with
        | Some reason when not (String.is_empty reason) ->
            finish_reason := Some reason
        | Some _ | None -> ());
        match object_field "delta" choice with
        | None -> ()
        | Some delta -> handle_delta delta)
  in
  let finalize_call index =
    let partial = Hashtbl.find partials index in
    match partial.name with
    | None ->
        Error
          (stream_error Llm.Error.Decode
             "local stream tool call is missing a function name")
    | Some name -> (
        let id =
          match partial.call_id with
          | Some id -> id
          | None -> Printf.sprintf "local_call_%d" index
        in
        let raw_input =
          match Buffer.contents partial.input with "" -> "{}" | raw -> raw
        in
        match json_of_string raw_input with
        | Error message ->
            Error
              (stream_error Llm.Error.Decode
                 ("local tool-call arguments are not valid JSON: " ^ message))
        | Ok input -> (
            match Llm.Tool.Call.make ~id ~name ~input () with
            | call -> Ok call
            | exception Invalid_argument message ->
                Error
                  (stream_error Llm.Error.Decode
                     ("local tool call is malformed: " ^ message))))
  in
  let finalize () =
    terminal := true;
    match result_map finalize_call (List.rev !call_order) with
    | Error error -> emit (Llm.Stream.Failed error)
    | Ok calls ->
        List.iter
          (fun call ->
            emit (Llm.Stream.Event (Llm.Stream.Event.tool_call call)))
          calls;
        let parts = [] in
        let parts =
          match Buffer.contents content with
          | "" -> parts
          | text -> Llm.Message.Assistant.text_part text :: parts
        in
        let parts =
          match Buffer.contents reasoning with
          | "" -> parts
          | text ->
              Llm.Message.Assistant.reasoning_part
                (Llm.Message.Assistant.Reasoning.make ~text ())
              :: parts
        in
        let parts =
          List.rev parts @ List.map Llm.Message.Assistant.tool_call calls
        in
        let assistant =
          match parts with
          | [] -> Llm.Message.Assistant.empty
          | parts -> Llm.Message.Assistant.make parts
        in
        let stop =
          match !finish_reason with
          | Some "stop" | None ->
              if List.is_empty calls then Some Llm.Response.Stop.end_turn
              else Some Llm.Response.Stop.tool_call
          | Some "tool_calls" -> Some Llm.Response.Stop.tool_call
          | Some "length" -> Some Llm.Response.Stop.length
          | Some "content_filter" -> Some Llm.Response.Stop.content_filter
          | Some other -> Llm.Response.Stop.of_label other
        in
        let response =
          Llm.Response.make ~model:requested_model
            ?response_model:!response_model ?response_id:!response_id
            ?provider_stop:!finish_reason ?stop ?usage:!usage assistant
        in
        Log.info (fun m ->
            let usage = Option.value !usage ~default:Llm.Usage.zero in
            m "request finished model=%s stop=%s input=%d output=%d"
              (Llm.Model.id requested_model)
              (Option.value !finish_reason ~default:"none")
              usage.Llm.Usage.input usage.Llm.Usage.output);
        emit (Llm.Stream.Finished response)
  in
  let rec next () =
    if not (Queue.is_empty pending) then Some (Queue.take pending)
    else if !terminal then None
    else if cancelled () then begin
      Log.debug (fun m ->
          m "request cancelled model=%s" (Llm.Model.id requested_model));
      terminal := true;
      Api.Chat.close api_stream;
      Some (Llm.Stream.Failed (cancelled_error ~phase:Llm.Error.Stream ()))
    end
    else
      match Api.Chat.next api_stream with
      | Some (Ok (Api.Chat.Chunk json)) ->
          handle_chunk json;
          next ()
      | Some (Ok Api.Chat.Done) ->
          finalize ();
          next ()
      | Some (Error error) ->
          fail (api_error ~phase:Llm.Error.Stream error);
          next ()
      | None ->
          if Option.is_some !finish_reason then begin
            (* Some servers end the body without a [DONE] sentinel. *)
            finalize ();
            next ()
          end
          else begin
            terminal := true;
            Some
              (Llm.Stream.Failed
                 (stream_error Llm.Error.Malformed_stream
                    "local stream ended without completion"))
          end
  in
  Llm.Stream.make ~close:(fun () -> Api.Chat.close api_stream) next

let server_binary ?(config = Config.default) () =
  Server.find_binary config.Config.server_binary

let fit_inputs id path =
  match Manifest.find id with
  | Some entry -> Some (Manifest.fit entry)
  | None ->
      if String.equal id path || Sys.file_exists path then gguf_fit_of_path path
      else None

(* The requested context clamps to the model's trained maximum and to what
   fits the memory budget: a server asked for more KV cache than the machine
   has fails to load, and the guard's job at load time is to degrade with a
   warning, never to block. *)
let context_for config id inputs =
  match inputs with
  | None -> config.Config.ctx_size
  | Some inputs -> (
      let requested =
        Int.min config.Config.ctx_size (Spice_modelfit.Model.max_context inputs)
      in
      match budget_for config with
      | None -> requested
      | Some budget -> (
          match Spice_modelfit.max_context ~budget inputs with
          | Some fitting when fitting < requested ->
              Log.warn (fun m ->
                  m
                    "model %s: context reduced to %d tokens to fit the memory \
                     budget (requested %d)"
                    id fitting requested);
              fitting
          | Some _ -> requested
          | None ->
              Log.warn (fun m ->
                  m
                    "model %s exceeds the memory budget; the server may fail \
                     to load it"
                    id);
              requested))

let client ~sw ~env ?http ?observe_download ?(config = Config.default) () =
  let accepts model =
    Llm.Provider.equal provider (Llm.Model.provider model)
    && Llm.Model.Api.equal api (Llm.Model.api model)
  in
  let run ~cancelled ~on_event request =
    if cancelled () then Error (cancelled_error ())
    else
      let model = Llm.Request.model request in
      let id = Llm.Model.id model in
      let* api_request = encode_request request in
      let* path =
        ensure_model_path ?http ?observe_download ~sw ~env ~cancelled config id
      in
      let inputs = fit_inputs id path in
      let ctx = context_for config id inputs in
      let need_bytes =
        Option.map
          (fun inputs ->
            Spice_modelfit.Estimate.total_bytes
              (Spice_modelfit.estimate ~context:ctx inputs))
          inputs
      in
      let* server =
        match
          Server.ensure ~sw ~env ~cancelled ~config ~model_path:path ~ctx
            ~need_bytes ~budget:(budget_for config)
        with
        | Ok _ as ok -> ok
        | Error message ->
            if cancelled () then Error (cancelled_error ())
            else startup_provider_error message
      in
      Eio.Switch.run ~name:"local.request" @@ fun request_sw ->
      let api_client =
        Api.Client.make ~base_url:(Server.base_url server) ~sw:request_sw ~env
          ()
      in
      Log.info (fun m -> m "request started model=%s" id);
      match Api.Chat.create_stream api_client api_request with
      | Error error -> Error (api_error error)
      | Ok api_stream ->
          Llm.Stream.iter_events
            (stream_events ~cancelled model api_stream)
            ~f:on_event
  in
  Llm.Client.make ~provider ~accepts ~run ()
