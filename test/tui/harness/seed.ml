(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Session-document fixtures. Replay is the blackbox way to render arbitrary
   transcript states: seed a document with finished turns, open it, golden the
   screen. Never seed mid-turn sessions. *)

let write_data project local text = Util.write_file (Project.data project local) text

let session ?title project id =
  let title_json =
    match title with
    | None -> ""
    | Some title -> Printf.sprintf {|"title":"%s",|} title
  in
  write_data project
    (Filename.concat "sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{%s"status":"active","cwd":"%s","created_at":1,"updated_at":1},"events":[]}|}
       id title_json (Project.root project))

let fork_session ?title project ~parent id =
  let title_json =
    match title with
    | None -> ""
    | Some title -> Printf.sprintf {|"title":"%s",|} title
  in
  write_data project
    (Filename.concat "sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{%s"status":"active","forked_from":{"parent":"%s","copied_events":0},"cwd":"%s","created_at":2,"updated_at":2},"events":[]}|}
       id title_json parent (Project.root project))

let prompt_session_titled project id ~title ~prompt =
  write_data project
    (Filename.concat "sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"%s","status":"active","cwd":"%s","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id title (Project.root project) prompt)

let prompt_session project id ~prompt =
  write_data project
    (Filename.concat "sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"status":"active","cwd":"%s","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"%s"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id (Project.root project) prompt)

let reasoning_session project id =
  write_data project
    (Filename.concat "sessions" (Filename.concat id "session.json"))
    (Printf.sprintf
       {|{"version":1,"id":"%s","metadata":{"title":"Thinking","status":"active","cwd":"%s","created_at":1,"updated_at":1},"events":[{"type":"turn_started","turn":{"id":"turn-1","input":{"type":"user","content":[{"type":"text","text":"think"}]},"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"options":{"tool_choice":{"type":"auto"},"response_format":{"type":"text"}},"host_tools":[]}},{"type":"response_appended","response":{"model":{"provider":"openai","api":"responses","id":"gpt-5.5"},"reasoning_summary":["hidden thought"],"assistant":{"parts":[{"type":"text","text":"visible answer"}]}}},{"type":"turn_finished","turn":"turn-1","outcome":{"type":"completed"}}]}|}
       id (Project.root project))

(* A persisted subagent run record linking [parent] to [child], below the
   workflow-artifacts root the runtime derives from the session store.
   [status_json] is the raw status object, e.g.
   [{"type":"completed","completed_at":62000,"summary":"..."}]. *)
let subagent_run project ~parent ~child ~role ~task ~status_json =
  write_data project
    (Filename.concat "subagents" (Filename.concat parent (child ^ ".json")))
    (Printf.sprintf
       {|{"child":"%s","parent":"%s","parent_turn":"turn-1","parent_call_id":"call-1","spawn":{"role":"%s","task":"%s"},"depth":1,"status":%s,"created_at":2000}|}
       child parent role task status_json)

let session_file_contains project id needle =
  let text =
    Util.read_file
      (Project.data project
         (Filename.concat "sessions" (Filename.concat id "session.json")))
  in
  Util.contains text needle

let sessions_contain project needle =
  let rec contains_file path =
    match Sys.is_directory path with
    | true ->
        Sys.readdir path
        |> Array.exists (fun name -> contains_file (Filename.concat path name))
    | false -> (
        match Util.read_file path with
        | text -> Util.contains text needle
        | exception Sys_error _ -> false)
    | exception Sys_error _ -> false
  in
  contains_file (Project.data project "sessions")
