(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Dune adapters for OCaml project tooling.

    This library is the Dune-facing bridge for {!Spice_ocaml}. It normalizes
    one-shot [dune describe] output into project descriptions and owns the
    session vocabulary used by Dune RPC integrations for build, test, and
    diagnostic updates.

    The adapter has two independent entry points:
    - {!Describe} runs short-lived [dune describe] commands and produces a
      project description.
    - {!Rpc.Instance} is the workspace-level Dune RPC state shared by tools and
      host watchers. *)

module Error : sig
  (** Structured errors returned by the Dune adapter. *)

  type source =
    | Workspace_describe
    | Tests_describe
    | Rpc  (** The adapter surface that produced a parse or protocol error. *)

  type t =
    | Command_failed of {
        argv : string list;
        cwd : string;
        status : int option;
        stderr : string;
      }
    | Parse_error of { source : source; offset : int option; message : string }
    | Path_error of { path : string; message : string }
    | Duplicate_library_uid of string
    | Unknown_library_uid of string
    | Invalid_state of { expected : string; actual : string }
    | Connection_failed of { endpoint : string; message : string }
    | Protocol_error of { message : string; payload : string option }
        (** The type for recoverable adapter errors.

            - [Command_failed] reports an unsuccessful [dune describe] process.
            - [Parse_error] reports an undecodable Dune output or RPC payload.
            - [Path_error] reports a path that cannot be resolved into the Spice
              workspace.
            - [Connection_failed] reports registry, socket, or connection setup
              failure. A missing running Dune RPC instance is represented as
              this case with endpoint ["dune rpc registry"].
            - [Protocol_error] reports a Dune RPC request, response, or version
              failure. *)

  val message : t -> string
  (** [message e] is a human-readable diagnostic for [e]. It is not stable
      enough for programmatic matching. *)

  val pp : Format.formatter -> t -> unit
  (** [pp ppf e] formats {!message} [e]. *)
end

module Describe : sig
  (** One-shot [dune describe] project adapter.

      This module has no dependency on Dune RPC. It runs Dune describe commands,
      decodes their current output format, and normalizes the result into
      {!Spice_ocaml.Project.t}. *)

  type prepare =
    argv:string list ->
    (string list * string array, string) result
  (** A host-supplied process preparation boundary. [Ok (argv, env)] is the
      exact invocation and environment to execute; [Error message] refuses the
      spawn. The preparation boundary owns the child environment rather than
      receiving an ambient candidate from the adapter. *)

  val workspace_args : ?with_deps:bool -> ?recursive:bool -> unit -> string list
  (** [workspace_args ()] is the [dune describe workspace] argv used by the
      adapter. [with_deps] defaults to [true]. [recursive] defaults to [true].

      The returned list includes [dune] and is suitable for permission checks
      and process execution. *)

  val tests_args : ?context:string -> unit -> string list
  (** [tests_args ()] is the [dune describe tests] argv used by the adapter.
      [context] selects a Dune build context when supplied. The returned list
      includes [dune]. *)

  val of_workspace_output :
    workspace:Spice_workspace.t ->
    string ->
    (Spice_ocaml.Project.t, Error.t) result
  (** [of_workspace_output ~workspace output] decodes
      [dune describe workspace --lang 0.1 --with-deps] output.

      Component dependency information is {!Spice_ocaml.Project.Deps.Unknown}
      when Dune did not emit dependency fields and
      {!Spice_ocaml.Project.Deps.Known} when it did.

      Errors are {!Error.Parse_error}, {!Error.Path_error},
      {!Error.Duplicate_library_uid}, {!Error.Unknown_library_uid}, or
      {!Error.Invalid_state} depending on the malformed input. *)

  val of_tests_output :
    workspace:Spice_workspace.t ->
    Spice_ocaml.Project.t ->
    string ->
    (Spice_ocaml.Project.t, Error.t) result
  (** [of_tests_output ~workspace project output] adds [dune describe tests]
      entries to [project].

      Existing project components are preserved. Test components are linked to
      components when Dune emits a known component identifier. *)

  val of_outputs :
    workspace:Spice_workspace.t ->
    workspace_output:string ->
    tests_output:string ->
    (Spice_ocaml.Project.t, Error.t) result
  (** [of_outputs] decodes and merges workspace and test describe outputs. *)

  val describe_project :
    prepare:prepare ->
    process_mgr:_ Eio.Process.mgr ->
    clock:_ Eio.Time.clock ->
    cwd:_ Eio.Path.t ->
    workspace:Spice_workspace.t ->
    ?env:string array ->
    ?cancelled:(unit -> bool) ->
    ?timeout_s:float ->
    unit ->
    (Spice_ocaml.Project.t, Error.t) result
  (** [describe_project ~prepare ~process_mgr ~clock ~cwd ~workspace ()] runs
      [dune describe workspace] and [dune describe tests] in the Eio directory
      [cwd], then returns the normalized project description.

      [prepare] confines or refuses each command before execution. [env]
      defaults to the process manager's inherited environment. [cancelled]
      defaults to a function that returns [false] and is checked before the
      first command starts. [timeout_s] defaults to a conservative wall-clock
      limit applied independently to each describe command. *)
end

module Rpc : sig
  (** Dune RPC client vocabulary and workspace-level state.

      {!Connection} is a single negotiated RPC socket. {!Instance} is the
      shareable workspace object that polls the Dune registry, chooses the
      matching endpoint, and keeps the latest-known diagnostic state for tools
      and host watchers. *)

  module Endpoint : sig
    (** Registered Dune RPC endpoint.

        A value is an opaque display token for the Dune RPC endpoint discovered
        for a workspace. It is carried by {!Instance.status} and diagnostic
        output; endpoint selection and connection are handled internally. *)

    type t
    (** The type for a Dune RPC endpoint registered for a workspace root. *)

    val to_string : t -> string
    (** [to_string t] is a human-readable endpoint description. *)

    val pp : Format.formatter -> t -> unit
    (** [pp ppf t] formats {!to_string} [t]. *)

    val equal : t -> t -> bool
    (** [equal a b] is [true] iff [a] and [b] denote the same endpoint. *)
  end

  module Build : sig
    (** Latest-known Dune build progress. *)

    type progress =
      | Waiting
      | In_progress of { complete : int; remaining : int; failed : int }
      | Failed
      | Interrupted
      | Success
          (** The type for Dune build progress events. [In_progress] counters
              are the values reported by Dune RPC. *)

    type t
    (** The type for latest-known build state. *)

    val empty : t
    (** [empty] is a build state with progress {!Waiting}. *)

    val progress : t -> progress
    (** [progress t] is the latest-known progress value. *)

    val running : t -> bool
    (** [running t] is [true] iff progress is {!Waiting} or {!In_progress}. *)

    val update : progress -> t -> t
    (** [update progress t] is [t] with latest progress [progress]. *)
  end

  module Diagnostic : sig
    (** Dune diagnostic identifiers, events, and latest-known stores. *)

    module Id : sig
      (** Stable identifier for a Dune diagnostic event. *)

      type t
      (** The type for non-empty diagnostic identifiers. *)

      val of_string : string -> t
      (** [of_string s] is the diagnostic identifier [s].

          Raises [Invalid_argument] if [s] is empty. *)

      val to_string : t -> string
      (** [to_string t] is the underlying Dune diagnostic identifier text. *)

      val equal : t -> t -> bool
      (** [equal a b] is [true] iff [a] and [b] are the same identifier. *)

      val compare : t -> t -> int
      (** [compare a b] orders identifiers lexicographically. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf t] formats {!to_string} [t]. *)
    end

    type id = Id.t
    (** The type for diagnostic identifiers. *)

    type event =
      | Add of id * Spice_ocaml.Diagnostic.t
      | Remove of id
          (** The type for Dune diagnostic subscription updates. [Add] inserts
              or replaces a diagnostic. [Remove] deletes a diagnostic by id. *)

    module Store : sig
      (** Latest-known Dune diagnostic set.

          The store mirrors ocaml-lsp's Dune diagnostic lifecycle: diagnostic
          events update a current set, and disconnect clears the current set at
          the workspace instance level. *)

      type t
      (** The type for a diagnostic set keyed by Dune diagnostic id. *)

      val empty : t
      (** [empty] is the empty diagnostic set. *)

      val apply : event -> t -> t
      (** [apply event store] is [store] after applying [event]. *)

      val apply_many : event list -> t -> t
      (** [apply_many events store] applies [events] in list order. *)

      val to_list : t -> (id * Spice_ocaml.Diagnostic.t) list
      (** [to_list store] is the diagnostics in deterministic adapter order. *)

      val find : id -> t -> Spice_ocaml.Diagnostic.t option
      (** [find id store] is [Some diagnostic] if [id] is present and [None]
          otherwise. *)

      val clear : t -> t
      (** [clear store] is {!empty}. *)
    end
  end

  type event =
    | Build_progress of Build.progress
    | Diagnostics of Diagnostic.event list
    | Disconnected of string option
        (** The type for events emitted by a Dune RPC subscription run.

            [Diagnostics] contains the diagnostic add/remove events for a single
            Dune subscription poll. [Disconnected reason] means the connection
            ended; [reason] is present when the adapter has a textual
            explanation. *)

  module Connection : sig
    (** Single negotiated Dune RPC connection.

        Connections are low-level and scoped to one socket lifetime. Prefer
        {!Instance} for tools and host watchers so registry selection, reconnect
        policy, and latest-known state are shared per workspace. *)

    type t
    (** The type for a live Dune RPC connection. *)

    val with_connection :
      sw:Eio.Switch.t ->
      net:_ Eio.Net.t ->
      ?workspace:Spice_workspace.t ->
      Endpoint.t ->
      f:(t -> ('a, Error.t) result) ->
      ('a, Error.t) result
    (** [with_connection ~sw ~net endpoint ~f] opens [endpoint], negotiates the
        Dune RPC protocol, and runs [f] with a live connection. The connection
        is valid only during [f].

        [workspace] enables conversion of Dune diagnostic locations into
        workspace paths. Connection and protocol failures are returned as
        {!Error.Connection_failed} or {!Error.Protocol_error}. *)

    val endpoint : t -> Endpoint.t
    (** [endpoint t] is the connected endpoint. *)

    val workspace : t -> Spice_workspace.t option
    (** [workspace t] is the workspace used for path conversion, if supplied. *)

    val build : t -> Build.t
    (** [build t] is the connection-local latest-known build state. *)

    val diagnostics : t -> Diagnostic.Store.t
    (** [diagnostics t] is the connection-local latest-known diagnostic set. *)

    val build_dir : t -> (string, Error.t) result
    (** [build_dir t] requests Dune's build directory for [t]. *)

    val request_diagnostics : t -> (Diagnostic.Store.t, Error.t) result
    (** [request_diagnostics t] requests the current full diagnostic set and
        replaces [t]'s connection-local diagnostic store with it. *)

    val run : t -> on_event:(event -> unit) -> (unit, Error.t) result
    (** [run connection ~on_event] follows Dune progress and diagnostic
        subscriptions until the RPC connection ends or {!stop} is called. Each
        event is applied to [connection] before [on_event] is called. *)

    val stop : t -> unit
    (** [stop t] closes [t]'s underlying flow. *)
  end

  module Instance : sig
    (** Workspace-level Dune RPC state shared by tools and watchers.

        One instance should be created per Spice workspace and reused by the
        diagnostics tool and the host Dune watcher. The instance first discovers
        already-running Dune RPC servers through the registry. When a starter is
        supplied to {!create}, it can also lazily start Dune and wait for the
        matching endpoint to appear. This shared state keeps explicit tools and
        proactive host notices on the same endpoint and diagnostic store. *)

    type t
    (** The type for a workspace-level Dune RPC instance. *)

    (** The type for the latest Dune RPC endpoint discovery status. *)
    type status =
      | Found of Endpoint.t
          (** A matching Dune RPC endpoint is visible for the workspace. *)
      | Not_found  (** No matching Dune RPC endpoint is currently registered. *)
      | Lookup_failed of Error.t
          (** Endpoint discovery failed before a connection could be selected.
          *)

    module Start : sig
      (** Lazy startup hooks for Dune RPC instances. *)

      type t
      (** The type for a one-shot startup hook.

          A value starts an external process or service and may expose its
          latest human-readable status. It does not decide when startup is
          needed; {!Instance.t} does that after registry discovery finds no
          matching endpoint. *)

      val make :
        ?status:(unit -> string option) ->
        ?stop:(unit -> unit) ->
        (unit -> (unit, Error.t) result) ->
        t
      (** [make ?status run] is a startup hook backed by [run].

          [run] is called at most once by an {!Instance.t}. [status], when
          supplied, is read only after startup has been attempted and a matching
          RPC endpoint is still unavailable. The status text is diagnostic
          context for callers; it is not a structured protocol. [stop] stops
          resources owned by a successful [run]. *)

      val run : t -> (unit, Error.t) result
      (** [run t] starts the hook. It errors without calling the backing
          function after {!stop}. Callers should arrange their own one-shot
          policy if they invoke this directly. *)

      val stop : t -> unit
      (** [stop t] permanently disables startup and stops resources owned by a
          successful {!run}. It is idempotent. *)

      val dune_build_watch :
        sw:Eio.Switch.t ->
        prepare:Describe.prepare ->
        process_mgr:_ Eio.Process.mgr ->
        cwd:Eio.Fs.dir_ty Eio.Path.t ->
        unit ->
        t
      (** [dune_build_watch ~sw ~prepare ~process_mgr ~cwd ()] starts
          [dune build --root <cwd> --watch @all] in [cwd] as a switch-scoped
          background process.

          The child is killed when [sw] is released. If it exits before Dune RPC
          becomes available, its bounded stdout/stderr preview is exposed
          through {!status}. *)
    end

    val create :
      fs:_ Eio.Path.t ->
      net:_ Eio.Net.t ->
      workspace:Spice_workspace.t ->
      ?env:(string -> string option) ->
      ?start:Start.t ->
      ?sleep:(float -> unit) ->
      ?startup_timeout:float ->
      unit ->
      t
    (** [create ~fs ~net ~workspace ()] is a workspace-level Dune RPC instance.

        [fs] is used to poll Dune's registry. [net] is used to connect to the
        selected endpoint. [env] defaults to {!Sys.getenv_opt} and is used for
        XDG registry discovery.

        When [start] is supplied, the first connection attempt that finds no
        matching Dune RPC endpoint calls [start] once, then polls the registry
        for up to [startup_timeout] seconds. [sleep] supplies the wait
        primitive; if [sleep] is omitted, startup remains fire-and-check with no
        blocking wait. [startup_timeout] defaults to [3.0] seconds. [start] is
        not retried and is not used to restart an endpoint that exits later.
        Raises [Invalid_argument] if [startup_timeout] is negative.

        The value owns registry polling and the latest diagnostic state for
        [workspace]. *)

    val workspace : t -> Spice_workspace.t
    (** [workspace t] is the workspace whose Dune endpoint [t] selects. *)

    val endpoint : t -> Endpoint.t option
    (** [endpoint t] is the last endpoint selected by {!refresh},
        {!request_diagnostics}, or {!run}. It is [None] before discovery
        succeeds, after discovery sees no running Dune RPC instance, or after no
        endpoint has matched the workspace. *)

    val diagnostics : t -> Diagnostic.Store.t
    (** [diagnostics t] is the latest-known diagnostic set observed through [t].
        It is updated by successful diagnostic requests and subscription events,
        and cleared on disconnect events. *)

    val stop : t -> unit
    (** [stop t] stops the optional starter-owned background process, if one was
        started. It does not close external Dune RPC servers that Spice did not
        start. *)

    val refresh : t -> (Endpoint.t option, Error.t) result
    (** [refresh t] polls the Dune RPC registry and selects the endpoint whose
        root matches [workspace t].

        [Ok (Some endpoint)] updates {!endpoint}. [Ok None] means no matching
        Dune RPC instance is currently registered and clears {!endpoint}.
        [Error e] reports registry failures. *)

    val refresh_status : t -> status
    (** [refresh_status t] refreshes endpoint discovery and returns the
        corresponding structured status. *)

    val request_diagnostics :
      t -> (Endpoint.t * Diagnostic.Store.t, Error.t) result
    (** [request_diagnostics t] requests Dune's current full diagnostic set
        using a short-lived connection to the selected endpoint.

        On success it returns the endpoint used and the fresh diagnostic store,
        and updates {!endpoint} and {!diagnostics}. On failure the existing
        store is left as the latest-known value. *)

    val request_visible_diagnostics :
      t -> (Endpoint.t * Diagnostic.Store.t, Error.t) result
    (** [request_visible_diagnostics t] requests Dune's current full diagnostic
        set only when a matching endpoint is already visible in the registry.

        It polls the registry like {!refresh}, opens a short-lived connection to
        the visible endpoint, and updates {!endpoint} and {!diagnostics} on
        success. Unlike {!request_diagnostics}, it never triggers the optional
        lazy starter. It returns {!Error.Connection_failed} when no matching
        endpoint is visible. *)

    module Health : sig
      (** One-shot build-health verdict from Dune's current diagnostics.

          A verdict is the collapse of connectivity and diagnostic count into
          the fact a frontend shows at a glance. It is derived by
          {!build_health} and is not latched: each call re-queries Dune. *)

      type t =
        | Disconnected
            (** No matching Dune RPC endpoint is registered for the workspace,
                or registry discovery failed. Build diagnostics are unavailable,
                which is not an error. *)
        | Clean  (** Connected, with an empty current diagnostic set. *)
        | Failing of int
            (** Connected, with the current diagnostic count, which is at least
                [1]. *)
        | Unknown
            (** Connected, but the current diagnostic set could not be retrieved
                within the query bound. *)

      val equal : t -> t -> bool
      (** [equal a b] is [true] iff [a] and [b] are the same verdict. *)

      val pp : Format.formatter -> t -> unit
      (** [pp ppf t] formats [t] for diagnostics. *)
    end

    val build_health :
      t -> clock:_ Eio.Time.clock -> ?timeout_s:float -> unit -> Health.t
    (** [build_health t ~clock ()] is a one-shot build-health verdict for the
        workspace, derived from Dune's current diagnostic set.

        It polls the Dune RPC registry for a matching endpoint (as {!refresh}
        does) and, when one is found, opens a short-lived connection and
        requests the current diagnostic set, bounded to [timeout_s] wall-clock
        seconds (default [0.5]). A successful request updates {!endpoint} and
        {!diagnostics} and yields {!Health.Clean} for an empty set or
        {!Health.Failing} for a non-empty one; a missing endpoint or a discovery
        failure yields {!Health.Disconnected}; a connection failure or a timeout
        yields {!Health.Unknown}.

        Unlike {!run} and {!request_diagnostics}, this query never triggers the
        instance's lazy starter: it does not spawn Dune. It is intended to be
        cheap enough to call at frontend startup. *)

    val run : t -> on_event:(event -> unit) -> (unit, Error.t) result
    (** [run t ~on_event] follows Dune progress and diagnostic subscriptions
        using the selected endpoint until the RPC connection ends.

        Each event is applied to [t]'s latest-known state before [on_event] is
        called. Host watchers call this function and convert meaningful state
        changes into model-visible notices; connection failures are returned to
        the caller so the watcher can decide whether to report and retry. *)
  end
end

module Project_source : sig
  (** Fresh-or-snapshot project shape with build-lock awareness.

      Spice's own (and any user-owned) [dune build --watch] holds the Dune build
      lock, and a one-shot [dune describe] fails fast while it is held. This
      module lets the describe-backed tools coexist with a live watch: it holds
      a session-scoped boot snapshot of {!Spice_ocaml.Project.t} in memory —
      nothing is written to disk — and serves it when the lock is held, or a
      fresh describe when it is free.

      It bridges the one-shot {!Describe} adapter and the {!Rpc.Instance}
      registry, but takes both as {e injected closures} rather than a
      {!Rpc.Instance.t} and Eio capabilities. This keeps {!Describe} RPC-free,
      lets the host map a registry {!Rpc.Instance.status} to a lock verdict, and
      makes the fresh-or-snapshot state machine unit-testable with a fake
      describe and a fake registry status. The host wires the real
      {!Rpc.Instance.refresh_status} and {!Describe.describe_project} in the
      boot lock-free window (before its watcher takes the lock). *)

  type t
  (** The type for a session-scoped project-shape source. *)

  (** The registry verdict the host derives from {!Rpc.Instance.refresh_status}.
  *)
  type watch =
    | Watch_endpoint of string
        (** A registered Dune RPC watch holds the build lock; the payload is the
            endpoint display. *)
    | No_watch
        (** No registered Dune RPC endpoint is visible. A one-shot describe may
            still fail if a non-RPC [dune build] holds the lock; that case is
            told apart by the describe error string, not the registry. *)

  module Freshness : sig
    (** Evidence about which project shape a {!get} call was served. *)

    type t =
      | Fresh  (** Served from a one-shot describe run for this call. *)
      | Snapshot of {
          captured_at : float;
          drifted : bool;
          endpoint : string option;
        }
          (** Served from the in-memory boot snapshot because the build lock is
              held. [captured_at] is the Unix time the snapshot was taken,
              [drifted] is the host-set drift flag (see {!set_drifted}), and
              [endpoint] names the watch holding the lock when one is registered
              or is [None] for a non-RPC lock holder. *)
  end

  type blocked =
    | Blocked_by_watch of { endpoint : string option }
        (** The build lock is held and no boot snapshot is available. [endpoint]
            names the registered watch, or is [None] for a non-RPC holder. *)
    | Describe_error of Error.t
        (** A one-shot describe failed with a genuine project error, not a lock
            conflict. *)

  val create :
    refresh_status:(unit -> watch) ->
    describe:
      (cancelled:(unit -> bool) -> (Spice_ocaml.Project.t, Error.t) result) ->
    ?now:(unit -> float) ->
    unit ->
    t
  (** [create ~refresh_status ~describe ()] is a project-shape source holding no
      snapshot until {!capture} runs. [refresh_status] is polled by {!get}
      before any describe. [describe] runs a one-shot [dune describe]. [now]
      stamps snapshot capture times and defaults to {!Unix.gettimeofday}.
      Cancellation is not owned by the source; callers pass it to {!get}, which
      forwards it to [describe] only when a fresh describe is attempted. *)

  val capture : t -> (unit, Error.t) result
  (** [capture t] runs [describe] once and stores the result as the boot
      snapshot, resetting the drift flag. It must be called in the boot
      lock-free window, before the host's watch takes the build lock. [Ok ()]
      stores the snapshot; [Error e] leaves [t] without one — for instance a
      user-owned watch already held the lock at boot — so later {!get} calls
      degrade to {!Blocked_by_watch}. *)

  val set_drifted : t -> bool -> unit
  (** [set_drifted t drifted] records whether the workspace shape has changed
      since the snapshot was captured. The host flips this from its filesystem
      watch; {!get} reads it when serving from the snapshot. A fresh describe in
      {!get} resets it to [false]. *)

  val clear : t -> unit
  (** [clear t] removes the captured snapshot and resets drift. Hosts call it
      when a workflow disables project execution so later consumers cannot
      observe Build-mode project state. *)

  val get :
    t ->
    ?cancelled:(unit -> bool) ->
    unit ->
    (Spice_ocaml.Project.t * Freshness.t, blocked) result
  (** [get t ()] resolves the project shape registry-first:

      - [refresh_status] returns {!Watch_endpoint} → serve the boot snapshot
        with {!Freshness.Snapshot} evidence naming the endpoint, or
        {!Blocked_by_watch} when there is no snapshot. No describe is attempted,
        because a fresh one under the held lock would only fail fast.
      - [refresh_status] returns {!No_watch} → a one-shot [describe] runs.
        Success replaces the snapshot and returns it as {!Freshness.Fresh}; a
        lock-held describe error (dune's ["has locked the build directory"])
        serves the snapshot with {!Freshness.Snapshot} evidence naming no
        endpoint, or {!Blocked_by_watch} when there is no snapshot; any other
        error is {!Describe_error}.

      [cancelled] is forwarded to [describe] in the {!No_watch} path. It is not
      consulted before [refresh_status] and is not used when a visible watch
      lets [get] serve or reject from the snapshot alone. *)
end
