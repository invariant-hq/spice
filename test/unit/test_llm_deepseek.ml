(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
open Test_support
module Llm = Spice_llm
module Deepseek = Spice_llm_deepseek
module Json = Jsont.Json

let equal_error_kind msg kind error =
  equal string ~msg (Llm.Error.label kind)
    (Llm.Error.label (Llm.Error.kind error))

let with_temp_dir f =
  let dir = Filename.temp_file "spice-deepseek-test" "" in
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

let schema =
  json_object
    [
      ("type", Json.string "object");
      ( "properties",
        json_object [ ("path", json_object [ ("type", Json.string "string") ]) ]
      );
      ("required", Json.list [ Json.string "path" ]);
    ]

let read_file_tool =
  Llm.Tool.make ~name:"read_file" ~description:"Read a file."
    ~input_schema:schema ()

let user_transcript text =
  Llm.Transcript.of_list_exn [ Llm.Message.user_text text ]

let request ?tools ?options ?transcript ?(model_id = "q2-imatrix") () =
  let transcript = Option.value transcript ~default:(user_transcript "hello") in
  Llm.Request.make_exn ~model:(Deepseek.model model_id) ?tools ?options
    transcript

let client_startup_error ?(cancelled = fun () -> false) ?config request =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client = Deepseek.client ~sw ~env ?config () in
  match Llm.Client.stream ~cancelled client request with
  | Error error -> error
  | Ok stream -> (
      match Llm.Stream.next stream with
      | Some (Llm.Stream.Failed error) -> error
      | Some (Llm.Stream.Event _) | Some (Llm.Stream.Finished _) | None ->
          failf "expected startup error")

let model_and_config_contracts () =
  let model = Deepseek.model "q2-imatrix" in
  check "model provider"
    (Llm.Provider.equal (Llm.Model.provider model) Deepseek.provider);
  check "model api" (Llm.Model.Api.equal (Llm.Model.api model) Deepseek.api);
  equal string ~msg:"model id" "q2-imatrix" (Llm.Model.id model);
  expect_invalid_arg "model id cannot be empty" (fun () ->
      ignore (Deepseek.model ""));
  ignore (Deepseek.Config.make () : Deepseek.Config.t);
  expect_invalid_arg "model_dir cannot be empty" (fun () ->
      ignore (Deepseek.Config.make ~model_dir:"" ()));
  expect_invalid_arg "cache_dir cannot be empty" (fun () ->
      ignore (Deepseek.Config.make ~cache_dir:"" ()));
  expect_invalid_arg "ctx_size must be positive" (fun () ->
      ignore (Deepseek.Config.make ~ctx_size:0 ()));
  expect_invalid_arg "max_tokens must be positive" (fun () ->
      ignore (Deepseek.Config.make ~max_tokens:0 ()));
  expect_invalid_arg "temperature cannot be negative" (fun () ->
      ignore (Deepseek.Config.make ~temperature:(-0.1) ()));
  expect_invalid_arg "top_p must be finite" (fun () ->
      ignore (Deepseek.Config.make ~top_p:infinity ()));
  expect_invalid_arg "min_p cannot be negative" (fun () ->
      ignore (Deepseek.Config.make ~min_p:(-0.1) ()));
  ignore (Deepseek.Config.backend : [ `Metal | `Cuda | `Cpu ])

let expect_status msg = function
  | Ok status -> status
  | Error message -> failf "%s: %s" msg message

let artifact_status () =
  with_temp_dir @@ fun dir ->
  let config = Deepseek.Config.make ~model_dir:dir () in
  let canonical =
    expect_status "canonical" (Deepseek.Artifact.status ~config "q2-imatrix")
  in
  let alias = expect_status "alias" (Deepseek.Artifact.status ~config "q2") in
  let missing_path, missing_size =
    let open Deepseek.Artifact in
    match (canonical, alias) with
    | ( Missing { path; url; size },
        Missing { path = alias_path; url = alias_url; size = alias_size } ) ->
        equal string ~msg:"alias path" path alias_path;
        equal string ~msg:"alias url" url alias_url;
        equal int64 ~msg:"alias size" size alias_size;
        check "path is under model dir" (String.starts_with ~prefix:dir path);
        check "download url is huggingface"
          (String.starts_with ~prefix:"https://huggingface.co/" url);
        check "size is positive" (Int64.compare size 0L > 0);
        (path, size)
    | _ -> failf "expected missing managed artifact"
  in
  Out_channel.with_open_bin missing_path (fun oc ->
      Out_channel.output_string oc "x");
  begin match
    expect_status "installed" (Deepseek.Artifact.status ~config "q2-imatrix")
  with
  | Deepseek.Artifact.Installed { path } ->
      equal string ~msg:"installed path" missing_path path
  | Deepseek.Artifact.Missing _ | Deepseek.Artifact.Explicit_path _ ->
      failf "expected installed artifact"
  end;
  begin match
    expect_status "explicit missing"
      (Deepseek.Artifact.status ~config "/nope/model.gguf")
  with
  | Deepseek.Artifact.Explicit_path { path; exists } ->
      equal string ~msg:"explicit path" "/nope/model.gguf" path;
      check "explicit path absent" (not exists)
  | Deepseek.Artifact.Installed _ | Deepseek.Artifact.Missing _ ->
      failf "expected explicit path"
  end;
  let explicit = Filename.concat dir "explicit.gguf" in
  Out_channel.with_open_bin explicit (fun oc ->
      Out_channel.output_string oc "g");
  begin match
    expect_status "explicit present" (Deepseek.Artifact.status ~config explicit)
  with
  | Deepseek.Artifact.Explicit_path { path; exists } ->
      equal string ~msg:"explicit present path" explicit path;
      check "explicit path present" exists
  | Deepseek.Artifact.Installed _ | Deepseek.Artifact.Missing _ ->
      failf "expected explicit path"
  end;
  check "missing size survives installation check"
    (Int64.compare missing_size 0L > 0)

let artifact_prepare_explicit_paths () =
  with_temp_dir @@ fun dir ->
  let existing = Filename.concat dir "explicit.gguf" in
  Out_channel.with_open_bin existing (fun oc ->
      Out_channel.output_string oc "g");
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let http = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
  begin match
    Deepseek.Artifact.prepare ~sw ~env ~http
      ~cancelled:(fun () -> false)
      existing
  with
  | Ok () -> ()
  | Error error -> failf "prepare existing explicit path: %a" Llm.Error.pp error
  end;
  begin match
    Deepseek.Artifact.prepare ~sw ~env ~http
      ~cancelled:(fun () -> false)
      (Filename.concat dir "missing.gguf")
  with
  | Ok () -> failf "expected missing explicit path to fail"
  | Error error ->
      equal_error_kind "missing explicit path" Llm.Error.Provider error
  end

let unsupported_requests_do_not_resolve_models () =
  let json_options =
    Llm.Request.Options.make
      ~response_format:
        (Llm.Request.Options.Json_schema
           { name = "answer"; schema; strict = true })
      ()
  in
  let cases =
    [
      ( "media",
        request
          ~transcript:
            (Llm.Transcript.of_list_exn
               [
                 Llm.Message.user
                   [
                     Llm.Content.text "see";
                     Llm.Content.media ~media_type:"image/png" (`Base64 "abcd");
                   ];
               ])
          () );
      ("json schema", request ~options:json_options ());
      ( "required tool",
        let options =
          Llm.Request.Options.make ~tool_choice:Llm.Request.Options.Required ()
        in
        request ~tools:[ read_file_tool ] ~options () );
      ( "forced tool",
        let options =
          Llm.Request.Options.make
            ~tool_choice:(Llm.Request.Options.Tool "read_file") ()
        in
        request ~tools:[ read_file_tool ] ~options () );
      ( "unsupported reasoning",
        let options =
          Llm.Request.Options.make
            ~reasoning_effort:Llm.Request.Options.Reasoning_effort.Low ()
        in
        request ~options () );
    ]
  in
  List.iter
    (fun (name, request) ->
      let error = client_startup_error request in
      equal_error_kind name Llm.Error.Unsupported error)
    cases

let missing_models_fail_before_engine_load () =
  with_temp_dir @@ fun dir ->
  let config =
    Deepseek.Config.make ~model_dir:dir
      ~cache_dir:(Filename.concat dir "cache")
      ()
  in
  let known = client_startup_error ~config (request ~model_id:"q2" ()) in
  equal_error_kind "known missing model" Llm.Error.Provider known;
  check "known message names unavailable download"
    (String.includes ~affix:"automatic download is unavailable"
       (Llm.Error.message known));
  let explicit =
    client_startup_error ~config
      (request ~model_id:(Filename.concat dir "missing.gguf") ())
  in
  equal_error_kind "explicit missing model" Llm.Error.Provider explicit;
  check "explicit message names path"
    (String.includes ~affix:"does not exist" (Llm.Error.message explicit))

let startup_cancellation_does_not_resolve_models () =
  let error =
    client_startup_error ~cancelled:(fun () -> true) (request ~model_id:"q2" ())
  in
  equal_error_kind "startup cancellation" Llm.Error.Cancelled error

let () =
  run "spice.llm.deepseek"
    [
      test "model and config contracts" model_and_config_contracts;
      test "artifact status" artifact_status;
      test "artifact prepare explicit paths" artifact_prepare_explicit_paths;
      test "unsupported requests do not resolve models"
        unsupported_requests_do_not_resolve_models;
      test "missing models fail before engine load"
        missing_models_fail_before_engine_load;
      test "startup cancellation does not resolve models"
        startup_cancellation_does_not_resolve_models;
    ]
