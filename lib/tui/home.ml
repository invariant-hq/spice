(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Mosaic
open Prims

module Brief = struct
  type session = { id : Spice_session.Id.t; title : string; age : string }

  type t = {
    dune : Spice_ocaml_dune.Rpc.Instance.Health.t;
    worktree : Spice_diff.stats option;
    crs : Spice_cr.Occurrence.counts option;
    session : session option;
    account_absent : bool;
    warning : string option;
  }

  let relative_age ~now t =
    let delta_ms =
      Int64.sub
        (Spice_session.Time.to_unix_ms now)
        (Spice_session.Time.to_unix_ms t)
    in
    let secs =
      if Int64.compare delta_ms 0L <= 0 then 0
      else Int64.to_int (Int64.div delta_ms 1000L)
    in
    let minute = 60 in
    let hour = 60 * minute in
    let day = 24 * hour in
    let week = 7 * day in
    let month = 30 * day in
    let year = 365 * day in
    if secs < minute then "just now"
    else if secs < hour then Printf.sprintf "%dm ago" (secs / minute)
    else if secs < day then Printf.sprintf "%dh ago" (secs / hour)
    else if secs < week then Printf.sprintf "%dd ago" (secs / day)
    else if secs < month then Printf.sprintf "%dw ago" (secs / week)
    else if secs < year then Printf.sprintf "%dmo ago" (secs / month)
    else Printf.sprintf "%dy ago" (secs / year)
end

module Motion = struct
  (* The lockup's playback (08-brand.md §Motion, 12-home.md §Liveness): while the
     home is idle the pour cycles in full — all nine pour frames (each dropping a
     grain as the mound rises a step), then a beat's hold on the settled heap —
     and repeats; the first keystroke freezes it to the static lockup for the rest
     of the process. Reduced motion starts [Static] with no timer. [Pouring i] is
     the position in the cycle: [i < pour_len] plays a pour frame, the tail holds
     the settled lockup. *)
  type t = Static | Pouring of int

  (* The beat's hold on the settled heap between cycles: ~0.5s at the frame
     cadence (08-brand.md §Motion). The pour's last frame is the settled lockup
     region, so the hold simply dwells on it. *)
  let pour_len = Array.length Theme.pour_frames
  let hold_frames = 4
  let cycle_len = pour_len + hold_frames
  let init ~reduced = if reduced then Static else Pouring 0
  let freeze _ = Static
  let animating = function Static -> false | Pouring _ -> true

  let tick = function
    | Static -> Static
    | Pouring i -> Pouring ((i + 1) mod cycle_len)

  (* The heap is an exact byte-suffix of row 2 and the "  ·" aloft grain of
     row 1, so splitting on those known suffixes recovers the 18-column prefixes
     without measuring glyph widths; each frame's grain (row 1) and mound (row 2)
     region completes the lockup. *)
  let row1, row2 =
    match Theme.lockup with [ row1; row2 ] -> (row1, row2) | _ -> ("", "")

  let row1_prefix =
    let suffix = "  " ^ Theme.grain_aloft in
    String.sub row1 0 (String.length row1 - String.length suffix)

  let row2_prefix =
    String.sub row2 0 (String.length row2 - String.length Theme.heap)

  let rows (f : Theme.pour_frame) =
    [ row1_prefix ^ f.Theme.grain; row2_prefix ^ f.Theme.mound ]

  let lockup_rows = function
    | Static -> Theme.lockup
    | Pouring i ->
        (* Past the pour the hold dwells on the final frame — the settled lockup —
           before the cycle wraps back to the first grain. *)
        let idx = if i < pour_len then i else pour_len - 1 in
        rows Theme.pour_frames.(idx)
end

let default_style = Ansi.Style.default
let add_style = Ansi.Style.make ~fg:Theme.color_success ()
let del_style = Ansi.Style.make ~fg:Theme.color_error ()
let ok_glyph = Ansi.Style.make ~fg:Theme.color_success ()
let bad_glyph = Ansi.Style.make ~fg:Theme.color_error ()
let blank_row = box ~size:{ width = pct 100; height = px 1 } []
let sep = seg Theme.muted Theme.separator
let plural n = if n = 1 then "" else "s"

let grow_spacer =
  box ~flex_grow:1. ~flex_shrink:1. ~size:{ width = pct 100; height = px 0 } []

(* The inset composer: a 60-column frame centered on the stage, the width
   shrinking with the terminal so it keeps its margins (12-home.md §Layout). The
   component and its keys are the chat composer's — only this geometry differs. *)
let composer_width width = min 60 (max 24 (width - 8))

let composer_inset ~width composer =
  box ~flex_shrink:0.
    ~size:{ width = px (composer_width width); height = auto }
    [ composer ]

(* Display width in columns: UTF-8 scalar values counted one per column (a
   continuation byte begins [0b10……]), exact for the notice's plain text plus the
   odd em dash. *)
let display_width s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* Greedy word wrap to [width] columns; never splits a word, so an over-long
   word simply overflows its line. *)
let word_wrap ~width text =
  let flush acc cur = if cur = "" then acc else cur :: acc in
  let rec go acc cur = function
    | [] -> List.rev (flush acc cur)
    | word :: rest ->
        let candidate = if cur = "" then word else cur ^ " " ^ word in
        if display_width candidate <= width || cur = "" then
          go acc candidate rest
        else go (cur :: acc) word rest
  in
  go [] "" (String.split_on_char ' ' text)

(* Split [text] into styled runs, drawing each occurrence of [needle] in
   {!Theme.atom} and the rest in [base]. The welcome's lead line names spice, an
   unbolded-accent atom inside an otherwise default-fg line (12-home.md §Notice
   slot). *)
let highlight ~base ~needle text =
  let nlen = String.length needle in
  let rec go acc start i =
    if nlen = 0 || i + nlen > String.length text then
      let tail = String.sub text start (String.length text - start) in
      List.rev (if tail = "" then acc else seg base tail :: acc)
    else if String.sub text i nlen = needle then
      let before = String.sub text start (i - start) in
      let acc = if before = "" then acc else seg base before :: acc in
      go (seg Theme.atom needle :: acc) (i + nlen) (i + nlen)
    else go acc start (i + 1)
  in
  go [] 0 0

(* The notice slot: release/host announcements between the facts line and the
   composer (12-home.md §Notice slot). The [▎] bar is [accent] — a notice is
   spice speaking to its user, so it reads warm, not like chrome. The committed
   welcome grammar styles its lines by role: the lead line (index 0) is default
   foreground with the word "spice" an unbolded-accent atom, and every supporting
   line is [muted]. Each line word-wraps to the terminal so it never touches the
   frame; the block is sized to its widest line, so the stage centers it on its
   visible text and the bars stay registered. *)
let notice_block ~width lines =
  let inner = max 8 (width - 6) in
  let pieces =
    List.concat
      (List.mapi
         (fun idx line ->
           List.map
             (fun piece -> (idx = 0, piece))
             (word_wrap ~width:inner line))
         lines)
  in
  let content =
    List.fold_left (fun m (_, p) -> max m (display_width p)) 0 pieces
  in
  let render (lead, piece) =
    let runs =
      if lead then highlight ~base:default_style ~needle:"spice" piece
      else [ seg Theme.muted piece ]
    in
    box ~flex_direction:Flex_direction.Row
      ~size:{ width = auto; height = px 1 }
      [
        seg Theme.accent "▎ ";
        box ~flex_direction:Flex_direction.Row
          ~size:{ width = px content; height = px 1 }
          runs;
      ]
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = auto; height = auto }
    (List.map render pieces)

(* The workspace block centers on the stage as a unit — its widest line centers,
   the lines stay left-aligned within it (12-home.md §Workspace block). A muted
   label column padded to 11, then the facts. Titles truncate head-first behind a
   trailing ["…"] so the part that names the thing survives; treated as ASCII, one
   byte one column. *)
let label_field = 11

(* Each row shrinks to its own content so the block's parent column sizes to the
   widest line; the stage then centers that block. Left-aligned within (the row is
   its natural width, packed from the left). *)
let labeled label value =
  let pad = label ^ String.make (label_field - String.length label) ' ' in
  box ~flex_direction:Flex_direction.Row ~flex_shrink:0.
    ~size:{ width = auto; height = px 1 }
    (seg Theme.muted pad :: value)

(* The dune line leads the block and is always shown — it is spice's core loop.
   The glyph carries connectivity ([✓] connected in [success], [✗] disconnected
   in [error]); the state text is muted weather, a failing build the one caution
   (12-home.md §Workspace block, §Degraded). *)
let dune_row dune =
  let glyph_style, glyph, state_style, state =
    match dune with
    | Spice_ocaml_dune.Rpc.Instance.Health.Clean ->
        (ok_glyph, "✓", Theme.muted, "build clean")
    | Spice_ocaml_dune.Rpc.Instance.Health.Failing n ->
        (ok_glyph, "✓", Theme.warning, Printf.sprintf "%d error%s" n (plural n))
    | Spice_ocaml_dune.Rpc.Instance.Health.Unknown ->
        (ok_glyph, "✓", Theme.muted, "build unknown")
    | Spice_ocaml_dune.Rpc.Instance.Health.Disconnected ->
        (bad_glyph, "✗", Theme.muted, "diagnostics unavailable")
  in
  labeled "dune" [ seg glyph_style glyph; sep; seg state_style state ]

(* The logged-out line (12-home.md §States, 09-auth.md §9): [none] loud, then the
   [/login] pointer as an accent atom (like [/review]). It rides just under dune
   so dune still leads the block, and shows only when no provider is connected. *)
let account_row =
  labeled "account"
    [
      seg Theme.warning "none";
      seg Theme.muted " — ";
      seg Theme.atom "/login to connect";
    ]

let worktree_row (stats : Spice_diff.stats) =
  let files = stats.Spice_diff.files in
  labeled "worktree"
    [
      seg Theme.muted (Printf.sprintf "%d file%s changed" files (plural files));
      sep;
      seg add_style (Printf.sprintf "+%d" stats.Spice_diff.additions);
      seg default_style " ";
      seg del_style (Printf.sprintf "−%d" stats.Spice_diff.deletions);
      sep;
      seg Theme.atom "/review";
    ]

let crs_row (counts : Spice_cr.Occurrence.counts) =
  labeled "CRs"
    [
      seg Theme.muted
        (Printf.sprintf "%d open" counts.Spice_cr.Occurrence.open_);
      sep;
      seg Theme.muted
        (Printf.sprintf "%d addressed to spice"
           counts.Spice_cr.Occurrence.addressed);
    ]

(* The session line is the newest resumable session: its title in quotes (default
   fg), a muted age. The title truncates head-first to leave room for the age
   within the terminal width. *)
let session_row ~width (s : Brief.session) =
  let budget =
    max 1 (width - 2 - label_field - 3 - String.length s.Brief.age)
  in
  let title = truncate_tail ~width:(max 1 (budget - 2)) s.Brief.title in
  labeled "session"
    [
      seg default_style ("\"" ^ title ^ "\""); sep; seg Theme.muted s.Brief.age;
    ]

(* Short-terminal shedding (12-home.md §States): above the block's 16-row floor
   the facts drop bottom-up — session, then CRs — as rows shrink; the dune line
   and worktree stay to the floor, below which the whole block folds and the
   stage (lockup → composer → footer) survives longest. *)
let workspace_block ~width ~rows (brief : Brief.t) =
  let when_ cond xs = if cond then xs else [] in
  let facts =
    dune_row brief.Brief.dune
    :: (when_ brief.Brief.account_absent [ account_row ]
       @ (match brief.Brief.worktree with
         | Some s -> [ worktree_row s ]
         | None -> [])
       @ when_ (rows >= 18)
           (match brief.Brief.crs with Some c -> [ crs_row c ] | None -> [])
       @ when_ (rows >= 20)
           (match brief.Brief.session with
           | Some s -> [ session_row ~width s ]
           | None -> []))
  in
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = auto; height = auto }
    facts

(* Before the first load lands the block is one muted spinner line rather than a
   blank region that pops in (12-home.md §Workspace block). *)
let loading_row =
  box ~flex_direction:Flex_direction.Column ~flex_shrink:0.
    ~size:{ width = auto; height = auto }
    [ seg Theme.muted "⠋ loading workspace…" ]

(* Section row costs known ahead of the flex measure pass (the house pattern:
   pre-compute the geometry rather than trust the measure). Each is the section's
   full height INCLUDING the one blank the stage prepends, except the brand, which
   leads the stack. The brand is {!Banner.home}: the two lockup rows, a blank, and
   the facts line. The inset composer is the three-row frame (top rule, prompt,
   bottom rule); a multi-line draft grows it, but the stage is pinned to the idle
   (empty-draft) height, so a grown composer simply hangs a touch below centre. *)
let brand_height = 4
let composer_section_height = 4
let warning_section_height = 2

(* Short-terminal shedding floors (12-home.md §States). Under height pressure the
   stage sheds sections top-down so the footer — the shell's own row below the
   stage, never the stage's — always renders and the composer survives longest.
   The notice and the workspace block fold together below [stage_block_floor]
   (the notice is the least essential section, the first to shed, mirroring the
   workspace fold); the warning yields a little later; the composer folds only
   under [composer_floor], where keeping the footer wins. *)
let stage_block_floor = 16
let warning_floor = 11
let composer_floor = 10

(* The notice's rendered height: the leading blank plus one row per wrapped piece,
   wrapped exactly as {!notice_block} wraps it (same [inner] budget). *)
let notice_section_height ~width lines =
  match lines with
  | [] -> 0
  | _ ->
      let inner = max 8 (width - 6) in
      let pieces =
        List.concat_map (fun line -> word_wrap ~width:inner line) lines
      in
      1 + List.length pieces

(* The workspace block's row count, matching {!workspace_block}'s own shedding:
   the dune line always, the account line when logged out, the worktree row when
   it differs, CRs at [>= 18] rows, the session at [>= 20]. *)
let workspace_rows ~rows (brief : Brief.t) =
  let present = function Some _ -> 1 | None -> 0 in
  1
  + (if brief.Brief.account_absent then 1 else 0)
  + present brief.Brief.worktree
  + (if rows >= 18 then present brief.Brief.crs else 0)
  + if rows >= 20 then present brief.Brief.session else 0

let workspace_section_height ~rows = function
  | None -> 1 + 1 (* blank · the loading spinner *)
  | Some brief -> 1 + workspace_rows ~rows brief

let stage ~snapshot ~brief ~notice ~motion ~composer ~width ~rows =
  (* Each section below the lockup prepends its own single blank, so the whole
     block keeps a one-row rhythm — brand, notice, composer, workspace, warning —
     with no doubled gaps (12-home.md §Layout). *)
  let below section =
    match section with None -> [] | Some e -> [ blank_row; e ]
  in
  (* The footer is the shell's own row below the stage; reserve it so the stage's
     content can never displace it (12-home.md §States). *)
  let budget = rows - 1 in
  (* The composer is the primary affordance and folds only under [composer_floor].
     A panel that owns the region below passes [composer = None], so the inset
     composer is absent regardless of height (doc/plans/tui-next-surfaces.md
     §Panel geometry). *)
  let composer_shown =
    (match composer with Some _ -> true | None -> false)
    && rows >= composer_floor
  in
  (* The notice can ride above a panel, so it does not depend on the composer; it
     is the first section to shed below [stage_block_floor]. The workspace facts
     and the dangerous-config warning belong to the idle stage: a panel drops them
     so the pinned brand and notice sit alone above it, and a short terminal sheds
     them before the composer (12-home.md §States). *)
  let show_notice = notice <> [] && rows >= stage_block_floor in
  let show_workspace = composer_shown && rows >= stage_block_floor in
  let show_warning = composer_shown && rows >= warning_floor in
  let notice_h =
    if show_notice then notice_section_height ~width notice else 0
  in
  (* Pin the brand's top offset so it holds its centered idle position when a panel
     or the help sheet grows from below — the drop is the shell's one sanctioned
     jump (12-home.md §Layout, §The drop). The offset is a single px box computed
     from the stage height (terminal rows minus the reserved footer) against an
     idle content height that always counts the composer slot and the idle
     workspace/warning: it is therefore the same whether the composer is shown
     (prelude) or replaced by a panel, so the brand does not move across that
     transition. Only the bottom stays a grow spacer, absorbing the slack (and the
     overlay). *)
  let idle_workspace_h =
    if rows >= stage_block_floor then workspace_section_height ~rows brief
    else 0
  in
  let idle_warning_h =
    match brief with
    | Some { Brief.warning = Some _; _ } when rows >= warning_floor ->
        warning_section_height
    | _ -> 0
  in
  let idle_content =
    brand_height + composer_section_height + notice_h + idle_workspace_h
    + idle_warning_h
  in
  let top_gap = max 0 ((budget - idle_content) / 2) in
  let notice =
    if show_notice then Some (notice_block ~width notice) else None
  in
  let composer =
    if composer_shown then Option.map (composer_inset ~width) composer else None
  in
  let workspace =
    if show_workspace then
      Some
        (match brief with
        | None -> loading_row
        | Some brief -> workspace_block ~width ~rows brief)
    else None
  in
  let warning =
    match brief with
    | Some { Brief.warning = Some w; _ } when show_warning ->
        Some (seg Theme.warning w)
    | _ -> None
  in
  (* Vertical rhythm: a pinned top gap holds the brand at its centered idle row and
     the bottom grow spacer takes the rest — brand, notice, composer, then the
     workspace block beneath it — while the footer (owned by the shell) never
     moves. Every section centers as a unit; the workspace block's lines stay
     left-aligned within it. *)
  box ~key:"stage" ~flex_direction:Flex_direction.Column
    ~align_items:Align.Center ~flex_grow:1. ~flex_shrink:1.
    ~size:{ width = pct 100; height = auto }
    (List.concat
       [
         [
           box ~flex_shrink:0. ~size:{ width = pct 100; height = px top_gap } [];
           Banner.home snapshot ~rows:(Motion.lockup_rows motion);
         ];
         below notice;
         below composer;
         below workspace;
         below warning;
         [ grow_spacer ];
       ])
