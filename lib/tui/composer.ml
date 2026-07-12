(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic

module Input_mode = struct
  type t = Plain | Shell | History_search
end

type mode = Build | Plan | Review

(* The history walk is a zipper: [older]/[newer] flank the visited entry and
   [initial_draft] is the draft in progress when the walk began, restored when
   paging forward past the newest entry. *)
type history_cursor = {
  older : Draft.History_entry.t list;
  newer : Draft.History_entry.t list;
  initial_draft : Draft.t;
}

type t = {
  draft : Draft.t;
  history : Draft.History_entry.t list;
  history_cursor : history_cursor option;
  searching : bool;
  widget_desync : bool;
      (* The draft's visible text differs from the textarea's buffer: the next
         render pushes the draft value into the widget, so a cursor report
         arriving before that push refers to the old buffer and is stale. A
         controlled value push does not invalidate an in-flight on_cursor report
         (upstream mosaic quirk), so the composer tracks the divergence itself. *)
}

let init ?draft () =
  {
    draft =
      draft |> Option.map Draft.of_text |> Option.value ~default:Draft.empty;
    history = [];
    history_cursor = None;
    searching = false;
    widget_desync = false;
  }

let draft t = t.draft
let draft_text t = Draft.text t.draft
let is_blank t = Draft.is_blank t.draft

let input_mode t =
  if t.searching then Input_mode.History_search
  else if String.starts_with ~prefix:"!" (Draft.text t.draft) then
    Input_mode.Shell
  else Input_mode.Plain

let active_file_ref_token t =
  Draft.active_file_ref_token_span t.draft
  |> Option.map (fun span ->
      String.sub (Draft.text t.draft) (Draft.Span.first span)
        (Draft.Span.length span))

(* The textarea reports cursor positions as grapheme-cluster offsets while the
   draft stores byte offsets; both sides segment with [Matrix.Text], so the
   mapping is exact. Out-of-range offsets clamp to the nearest boundary. *)
let byte_of_grapheme text grapheme =
  if grapheme <= 0 then 0
  else begin
    let index = ref 0 in
    let result = ref (String.length text) in
    (try
       Matrix.Text.iter_graphemes
         (fun ~offset ~len:_ ->
           if !index = grapheme then begin
             result := offset;
             raise Exit
           end;
           incr index)
         text
     with Exit -> ());
    !result
  end

let grapheme_of_byte text byte =
  let count = ref 0 in
  (try
     Matrix.Text.iter_graphemes
       (fun ~offset ~len:_ ->
         if offset >= byte then raise Exit;
         incr count)
       text
   with Exit -> ());
  !count

let desync_after draft t =
  t.widget_desync || not (String.equal (Draft.text draft) (Draft.text t.draft))

(* [Edited]: [reported] is the buffer text the textarea just reported. The
   widget only diverges when atomic-range expansion makes the adapted draft
   differ from it. *)
let with_reported reported t =
  let updated = Draft.replace_visible_text reported t.draft in
  {
    t with
    draft = updated;
    widget_desync = not (String.equal (Draft.text updated) reported);
    history_cursor = None;
  }

(* An out-of-band draft change (paste, completion, history, clear): the widget
   still shows the old text until the next render pushes the new value. *)
let with_draft draft t =
  { t with widget_desync = desync_after draft t; draft; history_cursor = None }

let cursor_moved grapheme t =
  if t.widget_desync then
    (* The report predates the value push for the last out-of-band draft change;
       its offset refers to the old buffer text. Drop it — the controlled cursor
       re-syncs the widget on this frame's render. *)
    { t with widget_desync = false }
  else
    let byte = byte_of_grapheme (Draft.text t.draft) grapheme in
    if byte = Draft.cursor t.draft then t
    else { t with draft = Draft.with_cursor byte t.draft }

(* Record [entry] as the newest prompt-history item, as a submit would, so it is
   the first thing [History_previous] recalls. Used when a draft is discarded
   via the esc ladder or ctrl+c and saved for later recall. *)
let remember entry t =
  {
    t with
    history =
      entry
      :: List.filter
           (fun other -> not (Draft.History_entry.equal entry other))
           t.history;
    history_cursor = None;
  }

let with_history history t =
  let loaded =
    List.filter
      (fun prompt ->
        not
          (List.exists
             (fun entry -> Draft.History_entry.equal prompt entry)
             t.history))
      history
  in
  { t with history = t.history @ loaded; history_cursor = None }

let has_following_separator draft =
  let text = Draft.text draft in
  let cursor = Draft.cursor draft in
  cursor < String.length text
  &&
  match String.get text cursor with
  | ' ' | '\n' | '\r' | '\t' | '\011' | '\012' -> true
  | _ -> false

(* The visible mention keeps its [@] trigger — [@lib/draft.ml], quoted
   [@"a b/c.ml"] when the path has whitespace (03-composer.md §File
   completion); the ref's payload path stays bare. *)
let file_ref_label path =
  if String.exists Char.Ascii.is_white path && not (String.contains path '"')
  then "@\"" ^ path ^ "\""
  else "@" ^ path

let complete_file_ref path draft =
  let draft =
    Draft.replace_active_file_ref_token ~label:(file_ref_label path) ~path draft
  in
  if has_following_separator draft then draft else Draft.insert_text " " draft

let previous_history t =
  match (t.history_cursor, t.history) with
  | None, [] -> t
  | None, prompt :: older ->
      let draft = Draft.of_history_entry prompt in
      {
        t with
        widget_desync = desync_after draft t;
        draft;
        history_cursor = Some { older; newer = []; initial_draft = t.draft };
      }
  | Some { older = []; _ }, _ -> t
  | Some ({ older = prompt :: older; _ } as cursor), _ ->
      let draft = Draft.of_history_entry prompt in
      {
        t with
        widget_desync = desync_after draft t;
        draft;
        history_cursor =
          Some
            {
              cursor with
              older;
              newer = Draft.history_entry t.draft :: cursor.newer;
            };
      }

let next_history t =
  match t.history_cursor with
  | None -> t
  | Some { newer = []; initial_draft; _ } -> with_draft initial_draft t
  | Some ({ newer = prompt :: newer; _ } as cursor) ->
      let draft = Draft.of_history_entry prompt in
      {
        t with
        widget_desync = desync_after draft t;
        draft;
        history_cursor =
          Some
            {
              cursor with
              older = Draft.history_entry t.draft :: cursor.older;
              newer;
            };
      }

type msg =
  | Edited of string
  | Cursor_moved of int
  | Paste of string
  | Submit of string
  | Help_key
  | Complete_file_ref of string
  | Restore_history of Draft.History_entry.t
  | History_previous
  | History_next
  | Begin_history_search
  | End_history_search
  | Clear_to_history
  | Exit_shell
  | List_key of [ `Up | `Down | `Tab ]

type event =
  | Submitted of { text : string; entry : Draft.History_entry.t }
  | Blank_submitted
  | Draft_saved of Draft.History_entry.t
  | Help_requested

let update ?(submit_enabled = true) msg t =
  match msg with
  | Edited reported -> (with_reported reported t, [])
  | Cursor_moved grapheme -> (cursor_moved grapheme t, [])
  | Paste text -> (with_draft (Draft.insert_paste text t.draft) t, [])
  | Complete_file_ref path -> (with_draft (complete_file_ref path t.draft) t, [])
  | Restore_history entry -> (with_draft (Draft.of_history_entry entry) t, [])
  | History_previous -> (previous_history t, [])
  | History_next -> (next_history t, [])
  | Begin_history_search -> ({ t with searching = true }, [])
  | End_history_search -> ({ t with searching = false }, [])
  | Help_key -> (t, [ Help_requested ])
  (* The shell routes [List_key] before it ever reaches this fold; arriving
     here it means nothing to the composer itself. *)
  | List_key _ -> (t, [])
  | Exit_shell -> (with_draft Draft.empty { t with searching = false }, [])
  | Clear_to_history ->
      if Draft.is_blank t.draft then (t, [])
      else
        let entry = Draft.history_entry t.draft in
        let t = remember entry (with_draft Draft.empty t) in
        ({ t with searching = false }, [ Draft_saved entry ])
  | Submit value -> (
      if not submit_enabled then (t, [])
      else
        let draft = Draft.replace_visible_text value t.draft in
        match Draft.submit draft with
        | None -> (t, [ Blank_submitted ])
        | Some (submitted, cleared) ->
            ( {
                draft = cleared;
                history = submitted.Draft.submitted_history_entry :: t.history;
                history_cursor = None;
                searching = false;
                widget_desync = not (String.equal (Draft.text cleared) value);
              },
              [
                Submitted
                  {
                    text = submitted.Draft.submitted_text;
                    entry = submitted.Draft.submitted_history_entry;
                  };
              ] ))

(* Styled runs for the textarea: plain text in the surface default, atomic
   ranges (file refs, paste chunks) in [Theme.atom]. The runs concatenate to
   exactly the draft text, as the widget's span contract requires. *)
let spans_of_draft draft =
  let text = Draft.text draft in
  List.map
    (fun (span, kind) ->
      let first = Draft.Span.first span in
      let piece = String.sub text first (Draft.Span.length span) in
      let style =
        match kind with
        | Draft.Plain -> Ansi.Style.default
        | Draft.Atom -> Theme.atom
      in
      { Mosaic.text = piece; style })
    (Draft.runs draft)

(* The input grows with its wrapped content up to this many rows, then scrolls
   internally so the frame and footer never move (03-composer.md §Multiline). *)
let max_input_rows = 6

(* Enter submits; Shift+Enter and ctrl+j (linefeed) insert a newline
   (03-composer.md §Keybindings). *)
let submit_key_bindings =
  let binding = Mosaic_ui.Textarea.key_binding in
  [
    binding "return" Mosaic_ui.Textarea.Submit;
    binding "enter" Mosaic_ui.Textarea.Submit;
    binding "linefeed" Mosaic_ui.Textarea.Newline;
    binding ~shift:true "return" Mosaic_ui.Textarea.Newline;
    binding ~shift:true "linefeed" Mosaic_ui.Textarea.Newline;
    binding ~shift:true "enter" Mosaic_ui.Textarea.Newline;
  ]

(* Column width: one per UTF-8 scalar value (a continuation byte begins
   [0b10……]). The chip glyphs (⏸ ⏴) and agent names measure one column each. *)
let columns s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let horizontal_rule = "─"

let rule_fill n =
  if n <= 0 then ""
  else begin
    let buffer = Buffer.create (n * String.length horizontal_rule) in
    for _ = 1 to n do
      Buffer.add_string buffer horizontal_rule
    done;
    Buffer.contents buffer
  end

(* The rules' color: build stays gray unless a thread is addressed (the frame
   heats to accent); plan/review wear the mode color (03-composer.md §Mode-colored
   frame, §Agent chip). *)
let frame_rule_color ~mode ~agent =
  match mode with
  | Plan -> Theme.color_mode_plan
  | Review -> Theme.color_mode_review
  | Build -> (
      match agent with Some _ -> Theme.color_accent | None -> Theme.color_rule)

(* The prompt marker's own hue: build's marker is always accent even while its
   rules stay gray; plan/review markers take the mode color. *)
let frame_marker_color = function
  | Build -> Theme.color_accent
  | Plan -> Theme.color_mode_plan
  | Review -> Theme.color_mode_review

let top_rule ~width ~rule_color ~mode ~agent =
  let rule_style = Ansi.Style.make ~fg:rule_color () in
  let key =
    let mode =
      match mode with Build -> "build" | Plan -> "plan" | Review -> "review"
    in
    "composer.top_rule." ^ mode
    ^ if Option.is_some agent then ".agent" else ".root"
  in
  let mode_label =
    match mode with
    | Plan -> Some (Theme.mode_plan ^ " plan")
    | Review -> Some (Theme.mode_review ^ " review")
    | Build -> None
  in
  let agent_label = Option.map (fun agent -> "@" ^ agent) agent in
  (* A filled chip pads its label with one space each side, so its rendered
     width is [columns label + 2]; the fill spans the rest of the rule. *)
  let chip_width = function Some label -> columns label + 2 | None -> 0 in
  let fill =
    rule_fill (width - chip_width mode_label - chip_width agent_label)
  in
  let chip = function
    | Some label -> [ Theme.chip ~color:rule_color label ]
    | None -> []
  in
  (* The fill is sized to the exact remaining width, so it never actually
     wraps — but it must be [`Word], not [`None]: a no-wrap run as wide as the
     frame pins the inset's min-content width, which drives a Toffee intrinsic
     pass that measures the textarea at Min_content width — one grapheme per
     row — and the frame then reserves one blank row per typed character
     (bug-repro/README.md). *)
  box ~key ~flex_direction:Flex_direction.Row
    ~size:{ width = pct 100; height = px 1 }
    (chip mode_label
    @ [ text ~style:rule_style ~wrap:`Word ~flex_shrink:0. fill ]
    @ chip agent_label)

let bottom_rule ~width ~rule_color =
  box ~key:"composer.bottom_rule"
    ~size:{ width = pct 100; height = px 1 }
    [
      (* [`Word] for the same min-content reason as the top rule's fill. *)
      text
        ~style:(Ansi.Style.make ~fg:rule_color ())
        ~wrap:`Word (rule_fill width);
    ]

let marker_of ~mode input_mode =
  match input_mode with
  | Input_mode.Plain ->
      (Theme.cursor, Ansi.Style.make ~fg:(frame_marker_color mode) ~bold:true ())
  | Input_mode.Shell -> (Theme.shell_marker ^ " ", Theme.warning)
  | Input_mode.History_search ->
      (Theme.history_marker ^ " ", Ansi.Style.make ~fg:Theme.color_history ())

let placeholder_for ~override ~agent ~turn_running input =
  match override with
  | Some placeholder -> placeholder
  | None -> (
      match input with
      | Input_mode.Shell -> "shell command"
      | Input_mode.History_search -> "search history"
      | Input_mode.Plain -> (
          match agent with
          | Some agent -> "message @" ^ agent
          | None ->
              if turn_running then "queue a message — sends after this turn"
              else "message spice"))

let render ?(submit_enabled = true) ?(list_open = false) ?(mode = Build) ?agent
    ?placeholder ?(turn_running = false) ?(top_margin = 1) ~width ~on_msg t =
  let stored_value = Draft.text t.draft in
  let input = input_mode t in
  let marker_glyph, marker_style = marker_of ~mode input in
  let rule_color = frame_rule_color ~mode ~agent in
  let textarea_placeholder =
    placeholder_for ~override:placeholder ~agent ~turn_running input
  in
  let single_line = not (String.contains stored_value '\n') in
  (* Keys with a widget default the shell must own are intercepted on the
     textarea's own key handler: it is the only hook that runs before the
     widget's default action (an app key subscription runs after, too late).
     "?" on an empty plain draft is the shortcuts trigger; ↑/↓ surface as
     [List_key] for list navigation or the single-line history walk instead of
     moving the widget cursor; tab joins them only while a list is open. *)
  let on_key ev =
    let data = Event.Key.data ev in
    let modifier = data.Matrix.Input.Key.modifier in
    let plain_modifiers =
      (not modifier.Matrix.Input.Modifier.ctrl)
      && (not modifier.Matrix.Input.Modifier.alt)
      && not modifier.Matrix.Input.Modifier.super
    in
    let ctrl_char c =
      modifier.Matrix.Input.Modifier.ctrl
      &&
      match data.Matrix.Input.Key.key with
      | Matrix.Input.Key.Char u -> Uchar.equal u (Uchar.of_char c)
      | _ -> false
    in
    let list_key key =
      Event.Key.prevent_default ev;
      Some (on_msg (List_key key))
    in
    match data.Matrix.Input.Key.key with
    | Matrix.Input.Key.Char c
      when input = Input_mode.Plain
           && String.equal "" (String.trim stored_value)
           && plain_modifiers
           && Uchar.equal c (Uchar.of_char '?') ->
        Event.Key.prevent_default ev;
        Some (on_msg Help_key)
    | Matrix.Input.Key.Up when plain_modifiers && (list_open || single_line) ->
        list_key `Up
    | Matrix.Input.Key.Down when plain_modifiers && (list_open || single_line)
      ->
        list_key `Down
    | Matrix.Input.Key.Tab when list_open && plain_modifiers -> list_key `Tab
    | _ when list_open && ctrl_char 'p' -> list_key `Up
    | _ when list_open && ctrl_char 'n' -> list_key `Down
    | _ -> None
  in
  let on_submit =
    if submit_enabled then fun value -> Some (on_msg (Submit value))
    else fun _ -> None
  in
  box ~key:"composer" ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~margin:(margin_lrtb 0 0 top_margin 0)
    ~size:{ width = pct 100; height = auto }
    [
      top_rule ~width ~rule_color ~mode ~agent;
      box ~key:"composer.input" ~flex_direction:Flex_direction.Row
        ~size:{ width = pct 100; height = auto }
        [
          text ~style:marker_style ~wrap:`None ~flex_shrink:0.
            ~align_self:Align.Flex_start marker_glyph;
          textarea ~key:"composer.textarea" ~id:"spice-tui-composer"
            ~autofocus:true ~value:stored_value ~on_key
            ~cursor:(grapheme_of_byte stored_value (Draft.cursor t.draft))
            ~spans:(spans_of_draft t.draft) ~placeholder:textarea_placeholder
            ~placeholder_color:Theme.color_faint ~wrap:`Word
            ~key_bindings:submit_key_bindings ~flex_grow:1.
            ~size:{ width = auto; height = auto }
            ~min_size:{ width = auto; height = px 1 }
            ~max_size:{ width = auto; height = px max_input_rows }
            ~on_input:(fun value -> Some (on_msg (Edited value)))
            ~on_cursor:(fun ~cursor ~selection:_ ->
              Some (on_msg (Cursor_moved cursor)))
              (* Pastes reach the draft, never the widget's default insert: the
                 draft normalizes line endings and collapses large pastes into an
                 atomic placeholder, then pushes the result back as the
                 controlled value. *)
            ~on_paste:(fun ev ->
              Event.Paste.prevent_default ev;
              Some (on_msg (Paste (Event.Paste.text ev))))
            ~on_submit ();
        ];
      bottom_rule ~width ~rule_color;
    ]
