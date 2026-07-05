(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The unified [@] completion: a lazy, expand-on-demand file tree rendered as
    one selection list above the composer (03-composer.md §File completion open,
    03-ia-screens-overlays.md §Completions).

    The composer surfaces the active [@]-token; the shell strips its leading
    ["@"] and feeds the rest as the {!with_query} filter, then routes the arrow,
    tab, and enter keys through the pure transitions here. This module owns no
    I/O: it names the directories it needs loaded ({!request_loads}) and accepts
    their contents back ({!loaded}); the runtime does the filesystem read and
    ignore-set filtering and hands over the surviving {!item}s. Rows render
    through {!Completion_list} so the [@] list, the slash palette, and the
    ctrl+r history list read as one control. *)

(** {1:items Items} *)

(** The type for one row of the unified list.

    A directory renders with a trailing ["/"]; both files and directories key
    off the [+] glyph, agent threads off [*] ([◇] stays reserved for MCP
    resources and is not modeled). {!Agent_thread} is reserved for the wave that
    lands live threads: the directory tree never produces one, so this iteration
    the list is files and directories only. *)
type item =
  | File of Spice_path.Rel.t
      (** A workspace file at this root-relative path. *)
  | Directory of Spice_path.Rel.t
      (** A workspace directory; tab descends into it. *)
  | Agent_thread of { name : string }
      (** A live agent thread; mentioning it addresses the thread. Reserved —
          never produced this iteration. *)

(** {1:state State} *)

type t
(** The type for the [@]-completion state: the filter query, the selected row,
    and the expand-on-demand directory tree (each expanded directory is
    [Loading], [Loaded], or [Failed]). *)

val make : ?query:string -> unit -> t
(** [make ?query ()] is a fresh completion with the root directory unloaded and
    row [0] selected. [query] is the initial filter (the [@]-token without its
    ["@"]) and defaults to [""]. The root loads on the first {!request_loads}.
*)

val with_query : string -> t -> t
(** [with_query query t] sets the filter to [query] (the [@]-token minus its
    ["@"]). Matching is case-insensitive substring against each item's displayed
    path and its basename. The selection resets to row [0] when [query] differs
    from the current one, and is clamped to the surviving rows. *)

val select_next : t -> t
(** [select_next t] moves the selection to the next row, wrapping past the last
    to the first. *)

val select_previous : t -> t
(** [select_previous t] moves the selection to the previous row, wrapping past
    the first to the last. *)

(** {1:loading Lazy loading}

    The runtime services the tree: it reads each requested directory through
    [Spice_workspace_fs], drops ignored entries (the ignore set is the runtime's
    world-fact, not this module's), and returns the surviving items — or a
    message on failure. *)

val request_loads : t -> t * Spice_path.Rel.t list
(** [request_loads t] is [t] with every directory it still needs (the root, plus
    each expanded directory with no state yet) marked in-flight, paired with
    those directories. Marking them prevents a re-request while a load is in
    flight, so the runtime calls this after opening the list and after each
    transition, then issues one read per returned directory. *)

val loaded : dir:Spice_path.Rel.t -> (item list, string) result -> t -> t
(** [loaded ~dir result t] records [dir]'s load: [Ok items] populates it (the
    items the runtime kept, in filesystem order), [Error message] marks it
    failed with [message]. The selection is re-clamped to the new rows. A stale
    result for a directory no longer expanded is still recorded and simply not
    shown. *)

(** {1:keys Key transitions} *)

val enter : t -> item option
(** [enter t] is the selected {!item} to complete, or [None] when the list is
    empty. The shell inserts it as an atomic mention (a directory keeps its
    trailing ["/"]) and closes the list; a future thread row addresses the
    thread. Enter never descends and never sends the draft while the list is up.
*)

(** The result of {!tab}. *)
type tab_result =
  | Descended of t
      (** Tab on a directory expanded it in place; the list stays open. The
          runtime then services {!request_loads}. *)
  | Chosen of item
      (** Tab on a file or thread; the shell completes it and closes, exactly as
          {!enter}. *)
  | No_selection  (** The list is empty; tab does nothing. *)

val tab : t -> tab_result
(** [tab t] descends into the selected directory or completes the selected file
    or thread (see {!tab_result}). Unlike the slash palette, the [@] list has no
    shared-prefix completion — the filename is edited in the draft directly. *)

(** {1:view View} *)

val view : width:int -> t -> _ Mosaic.t
(** [view ~width t] renders the list above the composer's top rule through
    {!Completion_list}: a 5-row window centered on the selection, each row a
    kind glyph and the item's displayed path middle-truncated to [width] (the
    filename is the signal). While the root is loading it is [loading files…];
    on a root failure it is the [! message] error line; an empty workspace is
    [no files] and a filter with no matches is [no matching files]. *)
