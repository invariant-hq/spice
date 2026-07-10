(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

(* A running tool keeps its claim (so a header can name it), the time it started
   (so the tail can show elapsed), and the live output accumulated from its
   [Tool_updated] text deltas (so a running shell shows the same constant-height
   3-line tail as the reasoning ticker, 02-tools.md §Shell). *)
type running = {
  claim : Spice_session.Tool_claim.Started.t;
  started : float;
  output : string;
}

(* A provider model artifact being prepared before a request: [label] is the
   working line's [Downloading <label>], [bytes] the humanized [received /
   total] progress ([None] before any byte arrives). *)
type downloading = { label : string; bytes : string option }

(* A tool call blocked on a permission decision (02-tools.md §Header, Awaiting
   permission): the reducer keeps the request id (to match the resolution) and
   the model call (to render the header). Tail-only while pending — nothing has
   run — it becomes the ordinary running row on approval, and settles to the
   document as [denied] on refusal or [interrupted] if the turn ends first. *)
type permission_pending = {
  request : Spice_session.Permission.Id.t;
  call : Spice_llm.Tool.Call.t;
}

(* The turn's lifecycle spine. [Idle] is at rest; [Pending] is a turn the shell
   has submitted whose durable Turn_started has not yet arrived, carrying the
   optimistic prompt echo (tail-only — never a document block — dropped by
   Turn_started as it emits the real User block); [Running] is live, between
   Turn_started and Turn_finished. [in_flight] holds from [Pending] onward so the
   spinner tick and esc-interrupt engage within a frame of submit. *)
type phase = Idle | Pending of string option | Running

(* The cooperative-interrupt axis, orthogonal to [phase]: [Interrupting] once esc
   flips a live turn to draining, [forcing] once a further esc escalates the
   drain to a hard cancel ([Live.force_interrupt]). *)
type drain = Not_interrupting | Interrupting of { forcing : bool }

type t = {
  phase : phase;
  turn_started : float;
  step_started : float option;
      (* the current model step, armed by Model_started *)
  assistant_stable : string;
      (* the Assistant_delta buffer through its last newline, discarded at the
         durable Assistant. Physically stable between newlines: the tail's
         markdown view memoizes on physical equality, so the stream re-parses
         once per completed line — a fresh whole-buffer string per delta would
         re-parse and re-lay-out the full message every delta, quadratic over a
         long response (the freeze). *)
  assistant_open : string;
      (* the buffer past its last newline — the line still being typed. The tail
         renders it as plain wrapped rows, never markdown: it is the one part
         that changes every delta, so it must stay O(line) to draw. *)
  reasoning : string;
      (* Reasoning_delta buffer, discarded at durable Assistant *)
  running : running list; (* in start order *)
  pending_host : (Spice_llm.Tool.Call.t * float) list;
      (* host calls awaiting their result, each with the time it started, so a
         running host tool renders an elapsed clock (02-tools.md §Header) until
         its settled [Host_call] arrives. In start order. *)
  workspace : Spice_mutation.Change.totals option;
      (* coalesced, flushed at settle *)
  injected : string list;
      (* injected-notice titles, accumulated and flushed at settle: a live-only
         event may not create a document block, so this waits for the durable
         Turn_finished. In arrival order. *)
  waiting : bool; (* a dialog or host question owns the keyboard *)
  drain : drain;
  committed_output : int;
      (* turn output-token spend from settled steps: the sum of each durable
         Assistant's usage output total (or, absent a durable snapshot, that
         step's last live snapshot). *)
  step_output : int;
      (* the current step's live output-token snapshot from Usage_updated,
         replaced by the durable Assistant so a settled step is never
         double-counted. Displayed spend is [committed_output + step_output]. *)
  compacting : int option;
      (* the projected input tokens while a compaction runs, driving the
         [Compacting conversation] verb; cleared by the durable compaction or a
         skip/failure. *)
  downloading : downloading option;
      (* a provider model artifact being fetched, driving the [Downloading …]
         verb; cleared when the next model step begins. *)
  todo : Spice_protocol.Todo.t option;
      (* the current turn's latest todo board (02-tools.md §Todo block), the live
         state a status-strip mirror renders above the composer. Each [todo_write]
         also settles an ordinary document block at its call site (see the
         Host_call arm and the [Transcript.append] fold), so this is a glance
         accessor, not the render path; it clears when the turn settles. *)
  permission_pending : permission_pending list;
      (* tool calls blocked on a permission decision, in request order. Populated
         by [Permission_requested], drained by [Permission_resolved] (approval →
         the call runs; denial → a settled [denied] block), and any still pending
         at [Turn_finished] settle [interrupted] so the document always records
         what the user interrupted their way out of. *)
}

let idle =
  {
    phase = Idle;
    turn_started = 0.;
    step_started = None;
    assistant_stable = "";
    assistant_open = "";
    reasoning = "";
    running = [];
    pending_host = [];
    workspace = None;
    injected = [];
    waiting = false;
    drain = Not_interrupting;
    committed_output = 0;
    step_output = 0;
    compacting = None;
    downloading = None;
    todo = None;
    permission_pending = [];
  }

let in_flight t =
  match t.phase with Idle -> false | Pending _ | Running -> true

(* [interrupting] is reached only from [Not_interrupting] and [forcing] only from
   [Interrupting { forcing = false }] (the esc ladder gates both), so each names
   its whole target state. *)
let interrupting t = { t with drain = Interrupting { forcing = false } }

let is_interrupting t =
  match t.drain with Interrupting _ -> true | Not_interrupting -> false

let forcing t = { t with drain = Interrupting { forcing = true } }

let is_forcing t =
  match t.drain with
  | Interrupting { forcing } -> forcing
  | Not_interrupting -> false

let waiting t = { t with waiting = true }
let todo_board t = t.todo

(* The shell marks a turn requested the instant the user submits, before the
   host's Turn_started arrives, so the prompt echo and working line show within a
   frame. [now] seeds the elapsed clock; [Turn_started] carries it forward (the
   user's clock started at submit). Built from [idle] so any settled prior turn's
   buffers are cleared. *)
let request ~now ~prompt _t =
  { idle with phase = Pending (Some prompt); turn_started = now }

let continue ~now _t =
  { idle with phase = Pending None; turn_started = now }

(* Rebase a still-pending turn's clock by [by] seconds. The pending timer runs in
   the drop-relative modeled clock (starting at 0 at the drop); the first
   runtime-stamped event reseeds the shell's clock to the wall clock, so the
   shell shifts the pending turn into that domain by the same delta — the elapsed
   then carries continuously across Turn_started instead of jumping. A no-op once
   the turn is running (no pending prompt), so it never perturbs a live turn's
   fixed start time. *)
let rebase_pending ~by t =
  match t.phase with
  | Pending _ -> { t with turn_started = t.turn_started +. by }
  | Idle | Running -> t

(* ── Reasoning title ─────────────────────────────────────────────────────── *)

let first_nonempty_line s =
  String.split_on_char '\n' s
  |> List.map String.trim
  |> List.find_opt (fun l -> l <> "")

let strip_bold l =
  let n = String.length l in
  if n >= 4 && String.sub l 0 2 = "**" && String.sub l (n - 2) 2 = "**" then
    Some (String.trim (String.sub l 2 (n - 4)))
  else None

let first_sentence s =
  let s = String.trim s in
  match String.index_opt s '.' with
  | Some i -> String.sub s 0 i
  | None -> (
      match String.index_opt s '\n' with
      | Some i -> String.sub s 0 i
      | None -> s)

(* The thought's leading [**bold**] line names the chain; failing that, its
   first sentence. The view truncates it to the reasoning head row's width. *)
let title_of body =
  match first_nonempty_line body with
  | None -> None
  | Some line -> (
      match strip_bold line with
      | Some x -> Some x
      | None -> Some (first_sentence body))

(* ── The fold ────────────────────────────────────────────────────────────── *)

let claim_key c =
  Spice_session.Tool_claim.Id.to_string (Spice_session.Tool_claim.Started.id c)

let reasoning_blocks ~duration reasoning_summary =
  let body = String.concat "\n\n" reasoning_summary in
  if String.trim body = "" then []
  else
    [
      Transcript.Reasoning
        { duration_s = duration; title = title_of body; body };
    ]

let assistant_blocks response =
  let text = Spice_llm.Response.text response in
  if String.trim text = "" then [] else [ Transcript.Assistant text ]

let workspace_notice (totals : Spice_mutation.Change.totals) =
  let { Spice_mutation.Change.files; total_additions; total_deletions } =
    totals
  in
  Transcript.Notice
    (Notice.Data
       {
         source = "workspace changed";
         facts =
           [
             Notice.Fact (Printf.sprintf "%d files" files);
             Notice.Change
               { added = total_additions; removed = total_deletions };
           ];
         atom = Some "/review";
         disclosable = true;
       })

let outcome_notice outcome =
  let open Spice_session.Turn.Outcome in
  match outcome with
  | Completed | Step_limit -> []
  | Interrupted _ -> [ Transcript.Notice Notice.Interrupt ]
  | Failed { message } ->
      [
        Transcript.Notice
          (Notice.Failure
             { message; next_step = "Tell spice how to proceed."; count = 1 });
      ]

(* Humanized bytes for the download clause: GB/MB/KB with one decimal, plain
   bytes below a kilobyte (matching the old TUI's [bytes_text]). *)
let bytes_text bytes =
  let value = Int64.to_float bytes in
  if value >= 1_000_000_000. then
    Printf.sprintf "%.1f GB" (value /. 1_000_000_000.)
  else if value >= 1_000_000. then Printf.sprintf "%.1f MB" (value /. 1_000_000.)
  else if value >= 1_000. then Printf.sprintf "%.1f KB" (value /. 1_000.)
  else Printf.sprintf "%Ld B" bytes

(* The download progress clause: [received / total], the total dropped when
   unknown and the whole clause dropped before any byte arrives. *)
let download_bytes (progress : Spice_protocol.Model_artifact.progress) =
  let received = progress.Spice_protocol.Model_artifact.received in
  match progress.Spice_protocol.Model_artifact.total with
  | Some total -> Some (bytes_text received ^ " / " ^ bytes_text total)
  | None -> if Int64.equal received 0L then None else Some (bytes_text received)

(* Fold CRLF to LF: the [\r] of every [\r\n] pair is dropped, the [\n] it
   precedes kept, so no line is gained or lost. Run over the open buffer joined
   to the incoming delta, it also resolves a pair whose [\r] and [\n] straddle
   two deltas — the trailing [\r] is dropped when the next delta's [\n] arrives.
   Keeps the plainly-rendered open line free of a stray carriage return. *)
let fold_crlf s =
  if not (String.contains s '\r') then s
  else begin
    let buffer = Buffer.create (String.length s) in
    let n = String.length s in
    for i = 0 to n - 1 do
      if not (s.[i] = '\r' && i + 1 < n && s.[i + 1] = '\n') then
        Buffer.add_char buffer s.[i]
    done;
    Buffer.contents buffer
  end

let apply ~now ~show_reasoning event t =
  let open Spice_protocol.Event in
  match event with
  | Turn_started turn ->
      (* Carry the elapsed clock from a pending request (the user's timer started
         at submit, already rebased into this event's wall-clock domain by the
         shell); a Turn_started with no pending request — the first durable turn
         of a resume — starts the clock now. [idle] drops the pending prompt; the
         durable User block below replaces it. *)
      let turn_started =
        match t.phase with Pending _ -> t.turn_started | Idle | Running -> now
      in
      let t = { idle with phase = Running; turn_started } in
      let blocks =
        match Spice_session.Turn.Input.text (Spice_session.Turn.input turn) with
        | Some text when String.trim text <> "" -> [ Transcript.User text ]
        | _ -> []
      in
      (t, blocks)
  | Model_started _ ->
      (* A new step: arm the timer, clear any deltas the previous step's durable
         Assistant did not (there is none until the model speaks), reset the
         live token snapshot, and clear any download clause — a request is now
         going out, so the artifact is prepared. *)
      ( {
          t with
          step_started = Some now;
          assistant_stable = "";
          assistant_open = "";
          reasoning = "";
          step_output = 0;
          downloading = None;
        },
        [] )
  | Assistant_delta { text } ->
      (* Fold CRLF to LF across the open buffer and the incoming delta, then move
         the completed prefix (through its last newline, its one re-parse) into
         the stable buffer and keep the rest as the open line. *)
      let joined = fold_crlf (t.assistant_open ^ text) in
      let t =
        match String.rindex_opt joined '\n' with
        | Some i ->
            let cut = i + 1 in
            {
              t with
              assistant_stable = t.assistant_stable ^ String.sub joined 0 cut;
              assistant_open = String.sub joined cut (String.length joined - cut);
            }
        | None -> { t with assistant_open = joined }
      in
      ({ t with downloading = None }, [])
  | Reasoning_delta { text } ->
      ({ t with reasoning = t.reasoning ^ text; downloading = None }, [])
  | Usage_updated usage ->
      (* The step's cumulative output snapshot so far. The durable Assistant
         below replaces it, so it counts the current step exactly once. *)
      ({ t with step_output = Spice_llm.Usage.output_total usage }, [])
  | Assistant response ->
      let duration =
        match t.step_started with
        | Some s -> int_of_float (Float.max 0. (now -. s))
        | None -> 0
      in
      (* /thinking off never ADDS the reasoning block (the invariant: hidden
         thinking is omitted, not filtered downstream). *)
      let reasoning =
        if show_reasoning then
          reasoning_blocks ~duration
            (Spice_llm.Response.reasoning_summary response)
        else []
      in
      let blocks = reasoning @ assistant_blocks response in
      (* Settle this step's output spend: the durable per-response usage is
         authoritative and replaces the live snapshot; absent it, the last live
         snapshot stands. Either way [step_output] resets, so the next step
         starts from zero. *)
      let step_final =
        match Spice_llm.Response.usage response with
        | Some usage -> Spice_llm.Usage.output_total usage
        | None -> t.step_output
      in
      ( {
          t with
          assistant_stable = "";
          assistant_open = "";
          reasoning = "";
          step_started = None;
          committed_output = t.committed_output + step_final;
          step_output = 0;
        },
        blocks )
  | Tool_started claim ->
      ( {
          t with
          running = t.running @ [ { claim; started = now; output = "" } ];
        },
        [] )
  | Tool_finished { claim; result } ->
      let key = claim_key claim in
      let running =
        List.filter
          (fun r -> not (String.equal (claim_key r.claim) key))
          t.running
      in
      (* Keep the todo mirror current when the board settles through the
         executable path (the accessor a status-strip reads). *)
      let todo =
        let call = Spice_session.Tool_claim.Started.call claim in
        if String.equal (Spice_llm.Tool.Call.name call) "todo_write" then
          match Spice_protocol.Todo.decode call with
          | Ok todos -> Some todos
          | Error _ -> t.todo
        else t.todo
      in
      ( { t with running; todo },
        [ Transcript.Tool (Tool_distill.of_tool_finished claim result) ] )
  | Host_call { call; result; _ } -> (
      let id = Spice_llm.Tool.Call.id call in
      let name = Spice_llm.Tool.Call.name call in
      match result with
      | None ->
          (* The call started (event.mli documents the two-emission cardinality:
             [None] at start, then the settled form). Record it with its start
             time so the tail renders a running row until it settles. *)
          ({ t with pending_host = t.pending_host @ [ (call, now) ] }, [])
      | Some result ->
          let pending_host =
            List.filter
              (fun (c, _) -> not (String.equal (Spice_llm.Tool.Call.id c) id))
              t.pending_host
          in
          (* [t.todo] mirrors the latest board for the status strip; a malformed
             input leaves the prior mirror standing. The block itself — the board,
             the answered question, a subagent-management act, plan/goal, or the
             generic done/failed row — is distilled by [Tool_distill.of_host_call],
             and the [Transcript.append] fold collapses two boards in a row. *)
          let todo =
            if String.equal name "todo_write" then
              match Spice_protocol.Todo.decode call with
              | Ok todos -> Some todos
              | Error _ -> t.todo
            else t.todo
          in
          ( { t with pending_host; todo },
            [ Transcript.Tool (Tool_distill.of_host_call call result) ] ))
  | Workspace_changed { total; _ } -> ({ t with workspace = Some total }, [])
  | Compaction _ ->
      ( { t with compacting = None },
        [ Transcript.Notice (Notice.Seam "compacted") ] )
  | Notices_injected notices ->
      (* Live-only: accumulate, flush at Turn_finished — no block here. *)
      ( {
          t with
          injected = t.injected @ List.map Spice_protocol.Notice.title notices;
        },
        [] )
  | Permission_requested requested ->
      (* Record the blocked call so the tail shows what is awaiting permission
         (02-tools.md §Header, Awaiting permission); the working line's
         [⋯ Waiting] is set alongside, not replaced. *)
      let pending =
        {
          request = Spice_session.Permission.Requested.id requested;
          call = Spice_session.Permission.Requested.tool_call requested;
        }
      in
      ( {
          t with
          waiting = true;
          permission_pending = t.permission_pending @ [ pending ];
        },
        [] )
  | Permission_resolved resolved ->
      (* Approval drops the pending row — the call now fires [Tool_started] and
         renders as the running row. Denial settles it [denied] to the document
         so the refusal is on the record. *)
      let id = Spice_session.Permission.Resolved.id resolved in
      let matched =
        List.find_opt
          (fun p -> Spice_session.Permission.Id.equal p.request id)
          t.permission_pending
      in
      let permission_pending =
        List.filter
          (fun p -> not (Spice_session.Permission.Id.equal p.request id))
          t.permission_pending
      in
      let blocks =
        match
          (matched, Spice_session.Permission.Resolved.decision resolved)
        with
        | Some p, Spice_session.Permission.Resolved.Deny _ ->
            [ Transcript.Tool (Tool_distill.denied p.call) ]
        | _ -> []
      in
      ({ t with waiting = false; permission_pending }, blocks)
  | Turn_finished { outcome; _ } ->
      (* Flush in transcript order: still-running tools settle interrupted, then
         any permission-pending calls settle interrupted (so the document records
         what the user interrupted their way out of, 02-tools.md §Header), then
         the coalesced workspace record, then the outcome notice. *)
      let running_blocks =
        List.map
          (fun r -> Transcript.Tool (Tool_distill.interrupted_claim r.claim))
          t.running
      in
      let permission_blocks =
        List.map
          (fun p -> Transcript.Tool (Tool_distill.interrupted_call p.call))
          t.permission_pending
      in
      let workspace_blocks =
        match t.workspace with Some w -> [ workspace_notice w ] | None -> []
      in
      let injected_blocks =
        List.map
          (fun title -> Transcript.Notice (Notice.Event title))
          t.injected
      in
      ( idle,
        running_blocks @ permission_blocks @ workspace_blocks @ injected_blocks
        @ outcome_notice outcome )
  | Compaction_progress progress ->
      (* Drive the [Compacting conversation] verb: a start arms the projection,
         and either the durable compaction above or a live skip/failure clears
         it. The intermediate summarizing/retrying deltas leave it standing. *)
      let compacting =
        match progress with
        | Started { projected_input; _ } -> Some projected_input
        | Skipped _ | Failed _ -> None
        | Summarizing _ | Retrying _ -> t.compacting
      in
      ({ t with compacting }, [])
  | Model_artifact progress ->
      (* Drive the [Downloading <label>] verb; the next model step clears it. *)
      ( {
          t with
          downloading =
            Some
              {
                label = progress.Spice_protocol.Model_artifact.label;
                bytes = download_bytes progress;
              };
        },
        [] )
  | Tool_updated { claim; update } ->
      (* Live-only: accumulate a running tool's text deltas so a running shell
         shows its 3-line output tail (02-tools.md §Shell). Progress points carry
         no stream text, so they leave the buffer untouched. *)
      let text =
        match update with
        | Spice_tool.Update.Text_delta s -> s
        | Spice_tool.Update.Progress _ -> ""
      in
      if text = "" then (t, [])
      else
        (* The buffer feeds only the constant-height 3-row tail, so it keeps a
           bounded suffix: the per-frame wrap stays O(window) and a chatty
           command cannot grow the reducer state without bound. The cut lands on
           a line start when one is in range. *)
        let cap_output s =
          let max_bytes = 4096 in
          let len = String.length s in
          if len <= max_bytes then s
          else
            let from = len - max_bytes in
            let from =
              match String.index_from_opt s from '\n' with
              | Some i when i + 1 < len -> i + 1
              | Some _ | None ->
                  (* No line start in range: step off any UTF-8 continuation
                     bytes so the suffix begins on a scalar boundary. *)
                  let rec scalar i =
                    if i < len && Char.code s.[i] land 0xC0 = 0x80 then
                      scalar (i + 1)
                    else i
                  in
                  scalar from
            in
            String.sub s from (len - from)
        in
        let key = claim_key claim in
        let running =
          List.map
            (fun r ->
              if String.equal (claim_key r.claim) key then
                { r with output = cap_output (r.output ^ text) }
              else r)
            t.running
        in
        ({ t with running }, [])
  (* Workspace_degraded leaves the tool result intact and is surfaced when
     workspace evidence gets its own view. *)
  | Workspace_degraded _ -> (t, [])

(* ── Views ───────────────────────────────────────────────────────────────── *)

let seg style s = text ~style ~wrap:`None ~flex_shrink:0. s
let blank_row = box ~size:{ width = pct 100; height = px 1 } []

let spinner_frame i =
  let f = Theme.spinner_frames in
  f.(i mod Array.length f)

let take_last n l = List.drop (List.length l - n) l

(* Display width in columns: one per UTF-8 scalar value (a continuation byte
   begins [0b10……]). *)
let display_width s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* Greedy word wrap to [width] columns; never splits a word, so an over-long
   word overflows its line. Linear in the text: the running line is a reversed
   word list carried with its column count, so no per-word candidate string is
   built and no width is rescanned — the tail wraps its buffers every frame,
   so a quadratic wrap here is a frame-budget bug, not a style choice. *)
let word_wrap ~width text =
  let line words = String.concat " " (List.rev words) in
  let flush acc words =
    match words with [] -> acc | words -> line words :: acc
  in
  let rec go acc words cols = function
    | [] -> List.rev (flush acc words)
    | "" :: rest when words = [] -> go acc [] 0 rest
    | word :: rest ->
        let word_cols = display_width word in
        if words = [] then go acc [ word ] word_cols rest
        else if cols + 1 + word_cols <= width then
          go acc (word :: words) (cols + 1 + word_cols) rest
        else go (flush acc words) [ word ] word_cols rest
  in
  go [] [] 0 (String.split_on_char ' ' text)

(* The last [n] wrapped rows of [buffer], wrapping only the physical-line
   suffix that yields them. The collapsed ticker and the shell tail show a
   constant-height window, so wrapping their whole buffer every frame would
   cost the full accumulated stream per frame — quadratic over a long response
   and the dominant term of the streamed-reasoning freeze. Whitespace-only
   lines are dropped, as the callers' windows always did. *)
let last_wrapped_rows ~width n buffer =
  let rec go acc count stop =
    if count >= n || stop <= 0 then acc
    else
      let start =
        match String.rindex_from_opt buffer (stop - 1) '\n' with
        | Some i -> i + 1
        | None -> 0
      in
      let line = String.sub buffer start (stop - start) in
      let rows = if String.trim line = "" then [] else word_wrap ~width line in
      go (rows @ acc) (count + List.length rows) (start - 1)
  in
  take_last n (go [] 0 (String.length buffer))

(* The expanded ticker's whole-buffer wrap, memoized on the buffer's physical
   identity and the wrap width. Renders run at the frame rate between
   reasoning deltas while the buffer value is untouched, so identity keys
   freshness exactly: each delta rebuilds the buffer string, missing the cache;
   every frame in between hits it. One slot suffices — at most one turn tail
   renders per frame. *)
let expanded_wrap_cache : (string * int * string list) ref = ref ("", 0, [])

let expanded_wrapped_rows ~width buffer =
  let key_buffer, key_width, rows = !expanded_wrap_cache in
  if key_buffer == buffer && key_width = width then rows
  else
    let rows =
      String.split_on_char '\n' buffer
      |> List.concat_map (fun l ->
          if String.trim l = "" then [] else word_wrap ~width l)
    in
    expanded_wrap_cache := (buffer, width, rows);
    rows

(* The reasoning ticker: a [∴ Thinking] header over a constant-height 3-line
   rolling window on the reasoning buffer, the oldest visible row faint as it
   exits (01-transcript.md §Reasoning). The window is over VISUAL lines: a
   reasoning summary is paragraph-shaped, so the buffer is greedy-wrapped to the
   tail width (less the 2-col indent) and the last three wrapped rows shown —
   otherwise a paragraph clips at the terminal edge and the ticker freezes on its
   stale head instead of the newest text. *)
let ticker ~width ~expanded reasoning =
  let content = max 1 (width - 2) in
  (* ctrl+o pins the ticker open on the whole wrapped buffer (01-transcript.md
     §Reasoning); otherwise the constant-height 3-line rolling window, its
     oldest visible row faint as it exits. An expanded ticker has no exiting
     row, so every line reads at full thinking weight. *)
  let rows, exit_row =
    if expanded then (expanded_wrapped_rows ~width:content reasoning, -1)
    else
      let window = last_wrapped_rows ~width:content 3 reasoning in
      let pad = List.init (3 - List.length window) (fun _ -> "") in
      (pad @ window, 0)
  in
  let row i line =
    let style = if i = exit_row then Theme.faint else Theme.thinking in
    box ~flex_direction:Flex_direction.Row
      ~size:{ width = pct 100; height = px 1 }
      [ seg Theme.thinking "  "; text ~style ~wrap:`None line ]
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    (seg Theme.thinking (Theme.thought ^ " Thinking") :: List.mapi row rows)

let assistant_tail ~width t =
  (* Deviation: 01-transcript.md reserves the accent dot for the running tool,
     but the streaming text block keeps one — a muted dot on visibly-growing text
     would read as settled. *)
  (* The stable prefix is the markdown view (memo-hit until the next completed
     line); the open line renders as plain pre-wrapped rows — raw until its
     newline lands, when the markdown pass takes it over. Wrapping happens here
     in OCaml, the ticker's idiom, so the row never depends on the text
     surface's measure pass. *)
  let stable =
    if String.trim t.assistant_stable = "" then []
    else [ Prose.view ~streaming:true t.assistant_stable ]
  in
  let open_rows =
    if String.trim t.assistant_open = "" then []
    else
      List.map
        (fun l ->
          box
            ~size:{ width = pct 100; height = px 1 }
            [ text ~style:Ansi.Style.default ~wrap:`None l ])
        (word_wrap ~width:(max 1 (width - 2)) t.assistant_open)
  in
  box ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = auto }
    [
      seg Theme.running (Theme.tool ^ " ");
      box ~flex_direction:Flex_direction.Column ~flex_grow:1. ~flex_shrink:1.
        (stable @ open_rows);
    ]

(* A running shell's constant-height 3-line output tail — the same idiom as the
   reasoning ticker (02-tools.md §Shell): the accumulated stream deltas
   greedy-wrapped to the indented tail width, the last three visual rows shown,
   short buffers padded so the block never changes height as output arrives. *)
let shell_running_tail ~width output =
  let content = max 1 (width - 6) in
  let window = last_wrapped_rows ~width:content 3 output in
  let pad = List.init (3 - List.length window) (fun _ -> "") in
  let row l =
    box ~flex_direction:Flex_direction.Row ~padding:(padding_lrtb 6 0 0 0)
      ~size:{ width = pct 100; height = px 1 }
      [ text ~style:Theme.muted ~wrap:`None l ]
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    (List.map row (pad @ window))

let running_row ~now ~width r =
  let elapsed = int_of_float (Float.max 0. (now -. r.started)) in
  let call = Spice_session.Tool_claim.Started.call r.claim in
  let verb = Tool_distill.verb_of_name (Spice_llm.Tool.Call.name call) in
  let tail_rows =
    match verb with
    | Tool_block.Shell -> [ shell_running_tail ~width r.output ]
    | _ -> []
  in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    (Tool_block.header verb
       ~argument:
         (Tool_block.header_argument ~width ~verb
            (Tool_distill.argument_of_call call))
       ~dot:Tool_block.Running
    :: Tool_block.result ~summary:"running"
         ~facts:[ Printf.sprintf "%ds" elapsed ]
         ()
    :: tail_rows)

(* A running host tool — one whose [Host_call] has fired with [result = None] but
   not yet settled (02-tools.md §Header): the same spinner-dot header + [running]
   result as [running_row], so a host tool that takes time (a [wait_subagents]
   blocked on children) is visible while it works, not only once it succeeds.
   Generic over every host tool; the argument names what it acts on via
   [Tool_distill.argument_of_call]. *)
let host_running_row ~now ~width (call, started) =
  let elapsed = int_of_float (Float.max 0. (now -. started)) in
  let verb = Tool_distill.verb_of_name (Spice_llm.Tool.Call.name call) in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    [
      Tool_block.header verb
        ~argument:
          (Tool_block.header_argument ~width ~verb
             (Tool_distill.argument_of_call call))
        ~dot:Tool_block.Running;
      Tool_block.result ~summary:"running"
        ~facts:[ Printf.sprintf "%ds" elapsed ]
        ();
    ]

(* A call blocked on a permission decision (02-tools.md §Header, Awaiting
   permission): the header with a muted dot — nothing has run, so the accent dot
   stays reserved for the running tool — over [⎿ ⋯ waiting on permission]. *)
let permission_row ~width p =
  let verb = Tool_distill.verb_of_name (Spice_llm.Tool.Call.name p.call) in
  box ~flex_direction:Flex_direction.Column
    ~size:{ width = pct 100; height = auto }
    [
      Tool_block.header verb
        ~argument:
          (Tool_block.header_argument ~width ~verb
             (Tool_distill.argument_of_call p.call))
        ~dot:Tool_block.Awaiting;
      Tool_block.result
        ~summary:(Theme.waiting ^ " waiting on permission")
        ~facts:[] ();
    ]

let tail ~now ~spinner:_ ~width ~show_reasoning ~expanded t =
  (* A submitted-but-not-yet-started prompt echoes here, rendered by the very
     block view its eventual settled User block uses, so Turn_started swapping it
     for the document block is seamless. *)
  let pending =
    match t.phase with
    | Pending (Some prompt) -> [ Transcript.user_block prompt ]
    | Pending None -> []
    | Idle | Running -> []
  in
  let parts =
    pending
    @ (if show_reasoning && String.trim t.reasoning <> "" then
         [ ticker ~width ~expanded t.reasoning ]
       else [])
    @ (if
         String.trim t.assistant_stable <> ""
         || String.trim t.assistant_open <> ""
       then [ assistant_tail ~width t ]
       else [])
    @ List.map (running_row ~now ~width) t.running
    (* Running host tools (wait/message/cancel/…): shown while working, EXCEPT
       when the turn is parked on a dialog or host question ([t.waiting]). A
       parked call is represented by its dialog and the static
       [⋯ Waiting for your answer] line; a spinner-led "running" row beside it
       would falsely say the model is working when it waits on the USER. Suppress
       keys on the waiting state, not on the dialog's identity — every host call
       renders its running row whenever the turn is not parked. *)
    @ (if t.waiting then []
       else List.map (host_running_row ~now ~width) t.pending_host)
    (* Calls awaiting a permission decision — nothing has run, so they are
       tail-only until approved (then a running row) or denied/interrupted (then
       a settled block). *)
    @ List.map (permission_row ~width) t.permission_pending
  in
  (* The tail reproduces the document's spacing law (01-transcript.md §Base
     grammar): one blank line between its own top-level parts. [None] when
     nothing renders, so the shell adds no blank between the document and an
     empty tail; the leading blank between the settled document and the tail's
     first part is the shell's job (it holds the document-empty truth). *)
  match parts with
  | [] -> None
  | parts ->
      let spaced =
        List.concat
          (List.mapi
             (fun i el -> if i = 0 then [ el ] else [ blank_row; el ])
             parts)
      in
      Some
        (box ~flex_direction:Flex_direction.Column
           ~size:{ width = pct 100; height = auto }
           spaced)

(* Elapsed as [45s] / [1m 05s] (the old TUI's [Ui.duration_text]). *)
let duration_text seconds =
  if seconds < 60 then string_of_int seconds ^ "s"
  else Printf.sprintf "%dm %02ds" (seconds / 60) (seconds mod 60)

(* A token count compacted to thousands with one decimal, e.g. [845], [1.3k],
   [23.1k] (the old TUI's [Ui.token_text]). *)
let token_text count =
  if count < 1000 then string_of_int count
  else
    let text = Printf.sprintf "%.1f" (Float.of_int count /. 1000.) in
    let text =
      if String.ends_with ~suffix:".0" text then
        String.sub text 0 (String.length text - 2)
      else text
    in
    text ^ "k"

let subagents_running t =
  List.length
    (List.filter
       (fun r ->
         match
           Tool_distill.verb_of_name
             (Spice_llm.Tool.Call.name
                (Spice_session.Tool_claim.Started.call r.claim))
         with
         | Tool_block.Task -> true
         | _ -> false)
       t.running)

let working_line ~now ~spinner t =
  if not (in_flight t) then None
  else
    let elapsed =
      duration_text (int_of_float (Float.max 0. (now -. t.turn_started)))
    in
    let spin = spinner_frame spinner in
    (* A spinner-led verb with a muted parenthetical: the always-present elapsed,
       then [extras], then [esc to interrupt]. *)
    let working verb extras =
      let parts =
        String.concat " · " ((elapsed :: extras) @ [ "esc to interrupt" ])
      in
      [
        seg Theme.running (spin ^ " ");
        seg Ansi.Style.default (verb ^ "… ");
        seg Theme.muted (Printf.sprintf "(%s)" parts);
      ]
    in
    let line =
      match t.drain with
      | Interrupting { forcing = true } ->
          (* Force is under way ([Live.force_interrupt] scheduled): the honest
             minimal readout, no further affordance to advertise. *)
          [
            seg Theme.running (spin ^ " ");
            seg Ansi.Style.default "Interrupting… ";
            seg Theme.muted "(forcing)";
          ]
      | Interrupting { forcing = false } ->
          (* The cooperative drain runs; a further esc hard-cancels it, so the
             line advertises the escalation (01-transcript.md §The working
             line). *)
          [
            seg Theme.running (spin ^ " ");
            seg Ansi.Style.default "Interrupting… ";
            seg Theme.muted "(esc again to force)";
          ]
      | Not_interrupting -> (
          if t.waiting then
            [
              seg Theme.muted (Theme.waiting ^ " ");
              seg Theme.muted "Waiting for your answer";
            ]
          else
            match t.downloading with
            | Some { label; bytes } ->
                working ("Downloading " ^ label) (Option.to_list bytes)
            | None -> (
                match t.compacting with
                | Some projected ->
                    working "Compacting conversation"
                      [ Printf.sprintf "↑ %s tokens" (token_text projected) ]
                | None ->
                    (* Trim-gated like the tail render (its assistant and ticker
                       parts show only on trimmed-non-empty buffers), so the verb
                       never says Working while only the ticker is visible. *)
                    let verb =
                      if
                        String.trim t.reasoning <> ""
                        && String.trim t.assistant_stable = ""
                        && String.trim t.assistant_open = ""
                        && t.running = []
                      then "Thinking"
                      else "Working"
                    in
                    let agents = subagents_running t in
                    let tokens = t.committed_output + t.step_output in
                    let extras =
                      (if agents > 0 then
                         [
                           Printf.sprintf "%d agent%s" agents
                             (if agents = 1 then "" else "s");
                         ]
                       else [])
                      @
                      if tokens > 0 then
                        [ Printf.sprintf "↓ %s tokens" (token_text tokens) ]
                      else []
                    in
                    working verb extras))
    in
    Some
      (box ~flex_direction:Flex_direction.Row
         ~size:{ width = pct 100; height = px 1 }
         line)
