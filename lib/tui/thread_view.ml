(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type status = Queued | Running | Blocked | Completed | Failed | Interrupted

(* The subagent status glyphs (00-overview.md §Glyph vocabulary: • running, ✓
   success). Theme.ml does not carry • and ✓ yet and is co-owned, so they live
   here as local constants until the vocabulary absorbs them — the same interim
   the status strip takes for its own glyphs (strip.ml). ✗ and ◌ are already in
   the theme vocabulary. *)
let running_glyph = "•"
let ok_glyph = "✓"

let of_run_status = function
  | Spice_protocol.Subagent_run.Status.Queued -> Queued
  | Spice_protocol.Subagent_run.Status.Running _ -> Running
  | Spice_protocol.Subagent_run.Status.Blocked _ -> Blocked
  | Spice_protocol.Subagent_run.Status.Completed _ -> Completed
  | Spice_protocol.Subagent_run.Status.Failed _ -> Failed
  | Spice_protocol.Subagent_run.Status.Cancelled _ -> Interrupted

let of_run run = of_run_status (Spice_protocol.Subagent_run.status run)

let glyph = function
  | Running | Blocked -> running_glyph
  | Completed -> ok_glyph
  | Failed -> Theme.failed
  | Queued | Interrupted -> Theme.interrupted

let style = function
  | Running -> Theme.running
  | Blocked | Interrupted -> Theme.warning
  | Completed -> Theme.success
  | Failed -> Theme.error
  | Queued -> Theme.muted

let word = function
  | Queued -> "queued"
  | Running -> "running"
  | Blocked -> "blocked"
  | Completed -> "completed"
  | Failed -> "failed"
  | Interrupted -> "interrupted"

let role_label role =
  match Spice_protocol.Subagent.Role.to_string role with
  | "" -> "Subagent"
  | value -> String.capitalize_ascii value

let compact value =
  let buffer = Buffer.create (String.length value) in
  let pending_space = ref false in
  String.iter
    (fun char ->
      match char with
      | ' ' | '\t' | '\n' | '\r' ->
          if Buffer.length buffer > 0 then pending_space := true
      | char ->
          if !pending_space then Buffer.add_char buffer ' ';
          pending_space := false;
          Buffer.add_char buffer char)
    value;
  Buffer.contents buffer

let clip ~max value =
  if String.length value <= max then value
  else
    (* Walk back off UTF-8 continuation bytes so the cut never splits a scalar
       value; the −3 reserves the appended ellipsis. *)
    let cut = ref (Stdlib.max 0 (max - 3)) in
    while !cut > 0 && Char.code value.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    String.sub value 0 !cut ^ "…"

let duration ~ms =
  let seconds = Int64.to_int (Int64.div (Int64.max 0L ms) 1000L) in
  let hours = seconds / 3600 in
  let minutes = seconds mod 3600 / 60 in
  let seconds = seconds mod 60 in
  if hours > 0 then Printf.sprintf "%dh %dm %ds" hours minutes seconds
  else if minutes > 0 then Printf.sprintf "%dm %ds" minutes seconds
  else Printf.sprintf "%ds" seconds

let elapsed ~now run =
  let span until =
    let created =
      Spice_session.Time.to_unix_ms (Spice_protocol.Subagent_run.created_at run)
    in
    Some (duration ~ms:(Int64.sub (Spice_session.Time.to_unix_ms until) created))
  in
  match Spice_protocol.Subagent_run.status run with
  | Spice_protocol.Subagent_run.Status.Queued -> None
  | Spice_protocol.Subagent_run.Status.Running _
  | Spice_protocol.Subagent_run.Status.Blocked _ ->
      span now
  | Spice_protocol.Subagent_run.Status.Completed { completed_at; _ } ->
      span completed_at
  | Spice_protocol.Subagent_run.Status.Failed { failed_at; _ } -> span failed_at
  | Spice_protocol.Subagent_run.Status.Cancelled { cancelled_at; _ } ->
      span cancelled_at

(* k-compact a token count: "845", "1.3k", "23.1k" (ported from the old TUI's
   [Ui.token_text]). *)
let compact_count count =
  if count < 1000 then string_of_int count
  else
    let text = Printf.sprintf "%.1f" (Float.of_int count /. 1000.) in
    let text =
      if String.ends_with ~suffix:".0" text then
        String.sub text 0 (String.length text - 2)
      else text
    in
    text ^ "k"

let tokens usage =
  "↓ "
  ^ compact_count usage.Spice_protocol.Subagent_run.Usage.completion_tokens
  ^ " tokens"

let settled_fact status =
  match status with
  | Spice_protocol.Subagent_run.Status.Queued
  | Spice_protocol.Subagent_run.Status.Running _ ->
      None
  | Spice_protocol.Subagent_run.Status.Blocked { blocker; _ } ->
      Some ("blocked: " ^ compact blocker)
  | Spice_protocol.Subagent_run.Status.Completed { summary; _ } ->
      Some (compact summary)
  | Spice_protocol.Subagent_run.Status.Failed { message; _ } ->
      Some ("failed: " ^ compact message)
  | Spice_protocol.Subagent_run.Status.Cancelled _ -> Some "interrupted"

(* The settled-agent line marker (02-tools.md §Subagents; subagent-tui.md
   decision 9). [●] is the agent-settlement mark, and the phrase carries the
   outcome ("finished" / "was interrupted" / "failed: <msg>") — a deliberate
   uniformity over the reference's per-outcome glyph switch (● finished vs ⏺
   interrupted), which the small-fixed-vocabulary rule (00-overview §Design
   principles) prefers. Not in the theme vocabulary yet, so a local constant. *)
let agent_glyph = "●"

let settled_line run =
  (* The task, quoted — the spec names the work, not the bare role
     (doc/plans/tui-next-threads.md §2.5). *)
  let task =
    clip ~max:48
      (compact
         (Spice_protocol.Subagent.Spawn.task (Spice_protocol.Subagent_run.spawn run)))
  in
  let facts =
    (match Spice_protocol.Subagent_run.usage run with
    | None -> []
    | Some usage ->
        [
          Printf.sprintf "%d tool uses"
            usage.Spice_protocol.Subagent_run.Usage.tool_uses;
          tokens usage;
        ])
    @ Option.to_list
        (elapsed ~now:(Spice_protocol.Subagent_run.updated_at run) run)
  in
  (* The outcome phrase, and the summary detail the notice hangs on a second
     line (capped; its disclosure lands with the switcher strip). *)
  let phrase, detail, severity =
    match Spice_protocol.Subagent_run.status run with
    | Spice_protocol.Subagent_run.Status.Completed { summary; _ } ->
        ("finished", Some (compact summary), `Status)
    | Spice_protocol.Subagent_run.Status.Cancelled _ ->
        ("was interrupted", None, `Status)
    | Spice_protocol.Subagent_run.Status.Failed { message; _ } ->
        ("failed: " ^ clip ~max:60 (compact message), None, `Problem)
    | Spice_protocol.Subagent_run.Status.Blocked { blocker; _ } ->
        ("blocked: " ^ clip ~max:60 (compact blocker), None, `Status)
    | Spice_protocol.Subagent_run.Status.Queued -> ("queued", None, `Status)
    | Spice_protocol.Subagent_run.Status.Running _ -> ("running", None, `Status)
  in
  let head =
    String.concat Theme.separator
      ((agent_glyph ^ " Agent \"" ^ task ^ "\" " ^ phrase) :: facts)
  in
  let line =
    match detail with None -> head | Some d -> head ^ "\n" ^ clip ~max:120 d
  in
  (line, severity)

type attention = Awaiting_reply | Permission_blocked

let attention_label = function
  | Awaiting_reply -> "✉ waiting on reply"
  | Permission_blocked -> "⋯ waiting on permission"
