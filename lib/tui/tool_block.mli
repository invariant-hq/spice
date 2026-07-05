(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The per-tool transcript grammar (02-tools.md).

    One shell for every tool call: a [⏺] header naming a bold verb and one
    primary argument, then a [⎿] result line carrying a human summary and facts.
    Beneath the result hangs the per-tool {!detail} the grammar auto-shows
    inline — a full diff for an {!Update}, a content preview for a {!Create}, the
    live todo board. Nothing raw ever reaches the transcript: no JSON, no
    [key=value], no diff [@@] stanzas leak through. Read/Search/generic calls
    carry only the summary; their content stays behind the disclosure [▸]. *)

(** A tool verb — the single source of truth for how a tool names itself. The
    generic fallback is {!Other}, the tool's own name rendered bold. *)
type verb =
  | Read
  | List
  | Search
      (** [search_text], [glob], and [ocaml_search_expressions] — text, path, and
          structural search all summarize as [Found …] *)
  | Update  (** modify a file *)
  | Create  (** a new file *)
  | Shell
  | Eval  (** ocaml_eval — a toplevel run, shaped like {!Shell} *)
  | Fetch
  | Web_search
  | Task
  | Todo
  | Dune
  | Diagnostics
  | Outline
  | Type
      (** ocaml_type_at — the result {i is} the type: the header names the
          position, the summary carries the type expression *)
  | Definition
      (** ocaml_find_definitions — the identifier is the argument, the resolved
          location the result *)
  | References
      (** ocaml_find_references — the occurrence counts are the result, the first
          locations disclosed beneath *)
  | Skill  (** skill — a loaded skill's guidance *)
  | Plan  (** propose_plan *)
  | Goal  (** update_goal *)
  | Message
      (** message_subagent / message_parent — a message delivered to a running
          agent, the quoted text the result *)
  | Cancel  (** cancel_subagent *)
  | Wait  (** wait_subagents *)
  | Question  (** ask_user — the question is the argument, the answer the result *)
  | Other of string

(** The header dot's state — the only colored glyph in the block. It never
    blinks: a running tool holds a steady accent dot ({!Theme.running}). *)
type dot =
  | Running  (** accent — the one running dot on screen *)
  | Ok  (** success green — the call's verdict at a glance *)
  | Failed  (** error red *)
  | Warned  (** warning — a warnings-only outcome, never red *)
  | Awaiting
      (** muted — a call blocked on a permission decision, nothing has run yet;
          the accent dot stays reserved for the running tool (02-tools.md
          §Header, Awaiting permission). ({!Awaiting}, not [Pending], so it does
          not collide with {!todo_status.Pending}.) *)

type diff_file = {
  label : string;
      (** the file's path, shown as a title row above its diff only when the
          block carries more than one file; a single-file diff hangs directly
          under the summary and the header already names the path *)
  patch : Mosaic.Diff.Patch.t;
      (** the precomputed line-level patch, built once when the block settles so
          replay re-renders it without re-diffing *)
}
(** One changed file in an {!Update} block. *)

(** A todo item projected to the three transcript states (02-tools.md §Todo
    block). [Cancelled] folds into {!Done} — both settle struck through — and
    [In_progress] is {!Active}. ({!Active} rather than [Running] so it does not
    collide with {!dot.Running}.) *)
type todo_status = Done | Active | Pending

type todo_item = { status : todo_status; content : string }

(** The detail hanging under the [⎿] result line, chosen per tool (02-tools.md).
    {!Summary} is the bare result line — Read, Search, and the generic fallback,
    whose content stays behind disclosure. The others auto-show the content the
    grammar mandates inline. *)
type detail =
  | Summary
  | Diff of diff_file list
      (** {!Update}: the full inline diff, always — every hunk, one shared
          gutter, add/remove backgrounds. One entry per changed file. *)
  | Preview of { lines : string list; overflow : int }
      (** {!Create}'s first content lines, or a failed {!Shell}'s trailing
          output, with [overflow] rows folded into the [… +N lines ▸] row. *)
  | Todos of todo_item list  (** the live todo board (02-tools.md §Todo block) *)

type t = {
  verb : verb;
  argument : string;  (** the primary argument; [""] renders no parentheses *)
  dot : dot;
  summary : string;  (** the [⎿] summary; the generic fallback uses ["done"] *)
  facts : string list;  (** trailing facts, joined by [ · ] *)
  disclosable : bool;
      (** a trailing [▸] marking content held behind disclosure — set for the
          summary-only tools (Read, Search), cleared where {!detail} already
          shows the content inline *)
  detail : detail;
}

val label : verb -> string
(** [label verb] is the verb's display name — ["Read"], ["Web Search"], and for
    {!Other} the tool's own registered name with its first letter capitalized
    (["ask_user"] renders ["Ask_user"]). *)

val preview : take:[ `First | `Last ] -> cap:int -> string list -> detail
(** [preview ~take ~cap lines] is the {!Preview} detail auto-showing at most
    [cap] lines of [lines] — the [`First] cap for {!Create}, the [`Last] for a
    failed {!Shell} tail — with the remainder folded into [overflow]. This is the
    one shared truncation law (02-tools.md §Truncation): when exactly one line
    would remain it is shown in full rather than counted, so the overflow never
    hides a single line behind [… +1 lines ▸]. *)

val header_argument : width:int -> verb:verb -> string -> string
(** [header_argument ~width ~verb argument] pre-truncates [argument] to the
    columns a [width]-wide header leaves after the dot, the [verb] label, and the
    parentheses, with a trailing [ … ] (02-tools.md §Truncation). A
    width-holding caller of {!header} passes the result as [~argument] so the
    [ … ] and the closing [)] always render, rather than relying on the flex
    clip (the Mosaic flex-truncate quirk drops the tail with no ellipsis). *)

val header : verb -> argument:string -> dot:dot -> _ Mosaic.t
(** [header verb ~argument ~dot] is the [⏺ Verb(argument)] row: the dot colored
    by [dot], the verb bold, the argument default foreground. A caller that holds
    the terminal width pre-truncates [argument] through {!header_argument} first;
    the one caller without a width (the shell-command running header) passes it
    raw and the argument flex-clips. *)

val result :
  ?disclosable:bool -> summary:string -> facts:string list -> unit -> _ Mosaic.t
(** [result ~summary ~facts ()] is the [⎿  summary · facts] line, indented under
    the header. [disclosable] (default [false]) appends a faint [▸]. The summary
    word-wraps under a hanging indent by design (a long error is never lost off
    the edge), so it is not pre-truncated — unlike the header and the detail
    rows. *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] is the whole block: {!header}, the {!result} summary line,
    and the per-tool {!detail} hanging beneath it. [width] is the terminal column
    count, threaded to the header argument and the detail rows (preview, todo,
    diff labels) so each pre-truncates rather than clipping off the edge. *)
