(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The review screen as a self-contained TEA component.

    [Spice_tui_review] is the whole review surface: the two-pane nav+diff split,
    the line cursor, marks and verdict, the CR compose dialog, and the
    live-refresh orchestration — packaged so the tui-next shell embeds it as one
    {!Spice_tui}-side [Screen] variant.

    The component is {e inert}: it holds review state and folds messages into
    new state, but performs no effect itself. Every filesystem read, snapshot
    load, persistence write, worktree watch, source-comment mutation, clock
    sleep, and agent submission is described as an {!Effect.t} the runtime runs;
    the runtime feeds results back as messages. This mirrors
    {!Spice_review.Live}: the pure state machine decides {e when} to reload and
    {e how} to fold results, the runtime does the work.

    {1 Embedding contract}

    The shell embeds a [surface] variant holding
    {!t], routes keys through
    {!key}, folds messages through {!update},
    interprets the resulting {!event}, and tags {!view}'s messages through
    [inject]. The review owns its keyboard, so an unclaimed key is discarded;
    ctrl+c remains the shell's global chord. {!Stay} forwards effects, {!Close}
    returns to chat, and {!Task_spice} submits the agent review turn. {!create}
    starts the open flow; the runtime builds the asynchronous completion
    messages below. *)

(** {1 Effects} *)

type request = int
(** The type for runtime-request tokens on {!Effect.Snapshot}: a completion must
    echo the token it was issued with so stale results are ignored. The
    component owns and increments this counter. Live-protocol requests use
    {!Spice_review.Live.Request.t} instead. *)

module Effect : sig
  (** The effects the runtime runs on the component's behalf; each carries the
      request token its completion must echo, and is fed back through the
      matching message constructor.

      Closing and submitting an agent review are shell decisions carried by
      {!event}, not effects. *)

  type t =
    | Snapshot of { request : request; base_spec : string option }
        (** Resolve [base_spec] (default [HEAD]) and load the first feature
            snapshot; complete with {!opened}. *)
    | Store of { root : string; key : string; record : Spice_review.Persist.t }
        (** Persist [record] under [.spice/reviews] keyed by [key]. Fire-and-
            forget. *)
    | Watch of { root : string }  (** Start watching the worktree at [root]. *)
    | Watch_stop  (** Stop the active worktree watch. *)
    | Sleep of { request : Spice_review.Live.Request.t; seconds : float }
        (** Sleep [seconds], then complete with {!tick} carrying [request]. *)
    | Load of {
        request : Spice_review.Live.Request.t;
        root : string;
        base : string;
        known : string option;
      }
        (** Reload the snapshot if it changed against fingerprint [known];
            complete with {!loaded}. *)
    | Mutate of {
        request : Spice_review.Live.Request.t;
        root : string;
        base : string;
        expected : string;
        op : Spice_review.Op.t;
      }
        (** Apply [op] to source, guarded by fingerprint [expected]; complete
            with {!mutated}. *)
end

(** {1 Messages} *)

type opened
(** The type for a completed snapshot load: the loaded feature, CR occurrences,
    fingerprint, restored persistence, and resolved labels. Opaque; built by the
    runtime with {!snapshot} and delivered to {!update} through {!opened}. *)

val snapshot :
  root:string ->
  base:string ->
  range:string ->
  store_key:string ->
  resolver:string ->
  feature:Spice_review.Feature.t ->
  crs:Spice_cr.Occurrence.t list ->
  fingerprint:string ->
  ?persisted:Spice_review.Persist.t ->
  unit ->
  opened
(** [snapshot ~root ~base ~range ~store_key ~resolver ~feature ~crs ~fingerprint
     ?persisted ()] is the loader result the runtime feeds back through
    {!opened}: the worktree [root], the resolved [base] commit and its [range]
    display label, the [store_key] under which review state persists, the
    [resolver] handle for authored CRs, the [feature] snapshot with its [crs]
    occurrences and loader [fingerprint], and the [persisted] record to restore
    when one exists. *)

type msg
(** The type for review messages. Most are internal (produced by {!key} and
    {!view}); the runtime constructs only the asynchronous completions below. *)

(** {2 Runtime-built completions}

    The runtime builds these from the results of the effects it ran. *)

val opened : request:request -> (opened, string) result -> msg
(** [opened ~request result] reports a {!Effect.Snapshot} completion. *)

val fs_changed : now:float -> msg
(** [fs_changed ~now] reports a watched-tree change at monotonic time [now]. *)

val tick : Spice_review.Live.Request.t -> now:float -> msg
(** [tick request ~now] reports a {!Effect.Sleep} completion. *)

val loaded :
  Spice_review.Live.Request.t ->
  ([ `Unchanged | `Loaded of Spice_review.Live.load ], string) result ->
  msg
(** [loaded request result] reports a {!Effect.Load} completion. *)

val mutated :
  Spice_review.Live.Request.t -> (Spice_review.Live.load, string) result -> msg
(** [mutated request result] reports a {!Effect.Mutate} completion. *)

val watch_failed : string -> msg
(** [watch_failed message] reports that the worktree watch could not start. *)

val save_failed : string -> msg
(** [save_failed message] reports a persistence-write failure. *)

(** {1 Lifecycle} *)

type t
(** The type for the review component: a loading, failed, or open review. Values
    are immutable. *)

(** The shell-owned outcome of a {!update}: what the shell does with the surface
    after folding a message. *)
type event =
  | Stay of Effect.t list
      (** Remain open; forward these effects to the runtime. *)
  | Close of Effect.t list
      (** Persist and stop the watch (the effects), then drop the screen and
          return to chat. *)
  | Task_spice of Effect.t list
      (** Persist and stop the watch (the effects), then submit the agent review
          turn (the [t] action). *)

val create : ?base_spec:string -> unit -> t * Effect.t list
(** [create ?base_spec ()] is a fresh review opening against [base_spec] (a
    revision spec such as ["main"], default ["HEAD"]) together with the initial
    effects — a {!Effect.Snapshot} request. *)

val update : msg -> t -> t * event
(** [update msg t] folds [msg] into [t], returning the new state and the
    shell-owned {!event}. Pure: stale completions are dropped, live-refresh
    debounce and mutation guards are honoured, and persistence/watch effects are
    emitted (inside the event) as the review changes. *)

(** {1 Keyboard} *)

val key : t -> Matrix.Input.Key.event -> msg option
(** [key t ev] is the message for key [ev], or [None] for a key the review owns
    but does nothing with (the screen owns its keyboard wholly, so an unclaimed
    key simply dies). While the compose dialog is open, printables and backspace
    fold into the draft; esc cancels; enter submits. ctrl+c is never seen here —
    the shell intercepts it as the global quit chord before routing to the
    surface. *)

(** {1 View} *)

val view : ?width:int -> ?height:int -> inject:(msg -> 'a) -> t -> 'a Mosaic.t
(** [view ~inject t] renders the review at the given terminal size. [inject]
    tags the component's own messages (nav/line clicks) into the shell's message
    type; the shell wires nothing else. *)
