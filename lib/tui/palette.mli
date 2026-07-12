(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The slash-command palette: completion state and view over {!Command}.

    The palette is the composer-anchored list that opens when the draft is a
    slash-command line (03-composer.md §Slash palette open). It is pure state
    driven by the shell: the composer's text {e is} the filter (the filter law,
    03-ia-screens-overlays.md), so the palette stores no input buffer of its own
    — the shell hands it the draft text after ['/'] each frame via
    {!with_query}, and the palette keeps only a selection that resets on query
    change and clamps as matches shrink. Rows, windowing, and the empty state
    render through {!Completion_list}; the row {e data} is {!Command}'s.

    {b Open and close are the shell's decision}, derived from the draft (a ['/']
    on a submit-eligible draft opens; backspacing past ['/'] or [esc] closes) —
    this module never decides visibility. While it is open the shell routes
    [↑]/[↓]/[ctrl+p]/[ctrl+n] to {!move}, [tab] to {!complete}, and [↵] to
    {!activate}. When no row matches, the shell closes the palette and submits
    the unchanged draft as an ordinary prompt.
*)

(** {1:types Types} *)

type t
(** The type for the palette's completion state: the current query and the
    selected row. *)

(** The type for what [↵] means for the current selection (see {!activate}). *)
type activation =
  | Run of Command.t
      (** The selected command takes no argument: the shell dispatches its
          {!Command.fate} and closes the palette. *)
  | Insert of string
      (** The selected command takes an argument: the string is the draft
          replacement ([/command ], with a trailing space), and the shell closes
          the palette so the argument can be typed (03-composer.md §Slash
          palette open). *)

(** {1:constructors Constructors} *)

val make : t
(** [make] is a freshly opened palette: an empty query with the first row
    selected. The shell immediately drives it with {!with_query}. *)

val with_query : string -> t -> t
(** [with_query q t] is [t] refiltered for query [q] — the draft text after
    ['/']. Matching is {!Command.filter} (implemented commands only,
    case-insensitive substring of slash or title). The selection resets to the
    first row when [q] differs from [t]'s query and otherwise clamps to the new
    match count. *)

(** {1:queries Queries} *)

val selected_command : t -> Command.t option
(** [selected_command t] is the highlighted command, or [None] when nothing
    matches. *)

(** {1:transitions Transitions} *)

val move : [ `Up | `Down ] -> t -> t
(** [move dir t] moves the selection one row, wrapping at the ends
    (05-overlays-pickers.md §Keybindings). With no matches [t] is unchanged. *)

val activate : t -> activation option
(** [activate t] is what [↵] does for the current selection, or [None] when
    nothing matches. The shell interprets [None] by closing the palette and
    submitting the unchanged draft through the ordinary composer path. *)

val complete : t -> string option
(** [complete t] is the [tab] completion: the longest common slash prefix of the
    current matches when it extends the typed ['/']-token, as a draft
    replacement, or [None] when there is nothing to add. The palette stays open
    and the list narrows (03-composer.md §Slash palette open). *)

(** {1:views Views} *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the match rows through {!Completion_list}: a slash
    column padded to the widest match, a [muted] description truncated to
    [width], and a [faint] argument hint for arg-taking commands; the selected
    slash is [accent]. With no matches it renders {!Completion_list.note}
    ["no matching commands"]. [width] is the render width the descriptions are
    pre-truncated to. *)
