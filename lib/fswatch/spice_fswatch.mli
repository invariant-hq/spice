(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Snapshot-based file watching for one local directory tree.

    A watcher observes one normalized absolute directory root by diffing
    snapshots. Native OS backends are wakeup sources only: all events report
    differences between the previous baseline snapshot and the current scan, not
    raw backend notifications.

    Event paths are root-relative {!Spice_path.Rel.t} values. The root itself is
    {!Spice_path.Rel.root}, rendered as [.], when the watched directory is
    deleted, recreated, or its observed metadata changes. Symlinks are observed
    as symlinks and are not traversed as directories. Changes that appear and
    disappear between two scans may produce no event. *)

(** {1:errors Errors} *)

module Error : sig
  (** Recoverable watcher errors. *)

  type t =
    | Invalid_root of { root : string; reason : string }
        (** [root] is not an absolute existing directory root accepted by
            {!make}. *)
    | Invalid_path of { path : string; reason : string }
        (** A watched filesystem entry named by [path] cannot be represented as
            a root-relative {!Spice_path.Rel.t}. *)
    | Io of { path : string; reason : string }
        (** Filesystem access failed while resolving or scanning [path].

            Concurrent deletion of entries being scanned is ignored. Other
            filesystem failures, such as permission errors, are reported. *)
    | Backend_unavailable of { backend : string; reason : string }
        (** Required wakeup [backend] cannot be started or has become unusable.

            [backend] is a stable diagnostic class such as ["native"], not a
            platform-specific backend name. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e].

      The text is for display. Match on {!type:t} for programmatic handling. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats [e] for diagnostics. *)
end

(** {1:events Events} *)

module Event : sig
  (** Snapshot-diff events. *)

  type kind =
    | Created
        (** The path is present in the current snapshot and absent from the
            previous baseline. *)
    | Deleted
        (** The path is absent from the current snapshot and present in the
            previous baseline. *)
    | Changed
        (** The path is present in both snapshots but its observed state
            changed.

            Directories observe kind, identity, ownership, and permissions.
            Other filesystem objects also observe size, mtime, and ctime.

            Replacement at the same path is [Changed] for that path, plus
            [Created] or [Deleted] for descendants that appear or disappear.
            Renames without a stable path are reported as [Deleted] and
            [Created]. *)

  type t = { path : Spice_path.Rel.t; kind : kind }
  (** One root-relative path that differs between two adjacent snapshots.

      [path] is {!Spice_path.Rel.root} for a change to the watched root. *)

  val equal : t -> t -> bool
  (** [equal a b] is [true] iff [a] and [b] have the same path and kind. *)

  val compare : t -> t -> int
  (** [compare a b] orders events by path and then by kind: [Created],
      [Deleted], [Changed]. The order is compatible with {!equal}. *)

  val pp_kind : Format.formatter -> kind -> unit
  (** [pp_kind ppf kind] formats [kind] for diagnostics. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf t] formats [t] for diagnostics. *)
end

(** {1:watchers Watchers} *)

type t
(** The type for one mutable watcher.

    A watcher owns a baseline snapshot that is advanced by {!poll}, {!next}, and
    {!reset}. Use baseline-mutating operations from one consumer fiber at a
    time. {!close} is idempotent and may be called from another fiber. *)

type backend = [ `Native | `Polling ]
(** Active wakeup backend.

    [`Native] wakes from native filesystem notifications. [`Polling] wakes on a
    timer. Both backends produce snapshot diffs, and no platform-specific native
    backend details are exposed. *)

type backend_preference = [ `Best | `Native | `Polling ]
(** Backend selection policy.

    [`Best] tries native notifications and falls back to polling. [`Native]
    requires a native backend and fails construction if none is available.
    [`Polling] always uses timed polling.

    A watcher made with [`Best] may later fall back from [`Native] to [`Polling]
    if the native backend fails. A watcher made with [`Native] reports
    {!Error.Backend_unavailable} instead. *)

val make :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?backend:backend_preference ->
  ?poll_interval:float ->
  ?settle_delay:float ->
  ?ignore:(Spice_path.Rel.t -> bool) ->
  root:string ->
  unit ->
  (t, Error.t) result
(** [make ~sw ~clock ~root ()] is a watcher for [root].

    [root] must be an absolute path to an existing directory. It is resolved to
    its real path and normalized before being stored in the watcher. The initial
    snapshot is captured during construction; the first {!poll} or {!next}
    reports only changes after construction.

    [ignore path] skips root-relative [path] and, when [path] is a directory,
    its descendants. If [ignore Spice_path.Rel.root] is [true], the whole tree
    is excluded. [ignore] may be called from an Eio systhread; it must be
    thread-safe and must not depend on Eio fiber-local state.

    [poll_interval] defaults to [0.25] seconds. It controls timed wakeups for
    [`Polling] and the correctness backstop used while [`Native] is active.
    [settle_delay] defaults to [0.05] seconds and coalesces native wakeups
    before scanning.

    [poll_interval] and [settle_delay] must be positive finite seconds; other
    values raise [Invalid_argument]. Invalid roots, initial scan failures, or an
    unavailable required native backend are returned as {!Error.t}.

    The watcher is closed automatically when [sw] is released. *)

val root : t -> string
(** [root t] is the normalized absolute real path observed by [t]. *)

val backend : t -> backend
(** [backend t] is the current wakeup backend.

    The value is intended for tests and diagnostics. It reports only whether
    wakeups are currently native or timer-based; it does not identify the OS
    notification mechanism. A watcher created with [`Best] may switch from
    [`Native] to [`Polling] if the native backend later becomes unusable. *)

val watch :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  ?backend:backend_preference ->
  ?poll_interval:float ->
  ?settle_delay:float ->
  ?ignore:(Spice_path.Rel.t -> bool) ->
  ?on_ready:(t -> unit) ->
  on_error:(Error.t -> unit) ->
  root:string ->
  f:(Event.t list -> unit) ->
  unit ->
  unit ->
  unit
(** [watch … ~f ()] starts a watcher on [root] and delivers each non-empty
    change batch to [f] until the returned stop function is called or [sw] is
    released.

    Construction is non-blocking: [watch] returns immediately and the initial
    scan runs in the background. Changes made after [watch] returns but before
    that scan completes may be captured in the initial baseline and not
    delivered as events. [on_ready t], when supplied, is called after the
    baseline has been captured and before [f] receives any batch.

    A construction failure, or a later filesystem failure that ends the loop, is
    passed to [on_error]. [f], [on_ready], and [on_error] run in the watcher's
    own fiber; exceptions raised by these callbacks are not caught.

    Calling the returned function, or releasing [sw], stops the watcher; both
    are idempotent. The watcher's arguments are those of {!make}; invalid timing
    values raise [Invalid_argument] before [watch] returns. *)

val poll : t -> (Event.t list, Error.t) result
(** [poll t] rescans immediately and advances [t]'s baseline to the current
    snapshot.

    [Ok events] is the {!Event.compare}-sorted diff from the previous baseline
    to the current snapshot. [events] may be empty. If the root has been
    deleted, the current snapshot is empty and includes deletion events for the
    root and all previously observed descendants. [Ok []] is returned if [t] is
    already closed. *)

val next : t -> (Event.t list option, Error.t) result
(** [next t] waits for the next non-empty change list.

    [Ok (Some events)] advances [t]'s baseline and contains one or more
    {!Event.compare}-sorted events. [Ok None] means [t] was closed before
    another non-empty diff was observed. Native wakeups are settled before
    scanning; polling timeouts are still used as a correctness backstop. *)

val reset : t -> (unit, Error.t) result
(** [reset t] replaces [t]'s baseline with the current snapshot without
    reporting the diff. Pending native wakeups are discarded before the new
    baseline is captured. [Ok ()] is returned if [t] is already closed. *)

val iter : t -> f:(Event.t list -> unit) -> (unit, Error.t) result
(** [iter t ~f] calls [f events] for each non-empty change list until [t] is
    closed or a filesystem error occurs.

    Exceptions raised by [f] are not caught and leave [t]'s baseline at the
    batch passed to [f]. *)

val close : t -> unit
(** [close t] releases backend resources and wakes fibers blocked in {!next}.
    Future {!poll} calls return [Ok []], future {!reset} calls return [Ok ()],
    and future {!next} calls return [Ok None]. [close] is idempotent. *)
