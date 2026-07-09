(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.fswatch" ~doc:"Filesystem watcher"

module Log = (val Logs.src_log log_src : Logs.LOG)

module Error = struct
  type t =
    | Invalid_root of { root : string; reason : string }
    | Invalid_path of { path : string; reason : string }
    | Io of { path : string; reason : string }
    | Backend_unavailable of { backend : string; reason : string }

  let message = function
    | Invalid_root { root; reason } ->
        Printf.sprintf "invalid watcher root %S: %s" root reason
    | Invalid_path { path; reason } ->
        Printf.sprintf "invalid watched path %S: %s" path reason
    | Io { path; reason } ->
        Printf.sprintf "filesystem error at %S: %s" path reason
    | Backend_unavailable { backend; reason } ->
        Printf.sprintf "%s backend is unavailable: %s" backend reason

  let pp ppf error = Format.pp_print_string ppf (message error)
end

let error e = Error e

module Event = struct
  type kind = Created | Deleted | Changed
  type t = { path : Spice_path.Rel.t; kind : kind }

  let rank_kind = function Created -> 0 | Deleted -> 1 | Changed -> 2
  let equal a b = Spice_path.Rel.equal a.path b.path && a.kind = b.kind

  let compare a b =
    match Spice_path.Rel.compare a.path b.path with
    | 0 -> Int.compare (rank_kind a.kind) (rank_kind b.kind)
    | order -> order

  let pp_kind ppf = function
    | Created -> Format.pp_print_string ppf "created"
    | Deleted -> Format.pp_print_string ppf "deleted"
    | Changed -> Format.pp_print_string ppf "changed"

  let pp ppf t =
    Format.fprintf ppf "%a %a" pp_kind t.kind Spice_path.Rel.pp t.path
end

type backend = [ `Native | `Polling ]
type backend_preference = [ `Best | `Native | `Polling ]

module Path_map = Map.Make (struct
  type t = Spice_path.Rel.t

  let compare = Spice_path.Rel.compare
end)

type file_kind = Directory | Regular_file | Symlink | Other

type file = {
  kind : file_kind;
  dev : int;
  ino : int;
  size : int64;
  mtime : float;
  ctime : float;
  perm : int;
  uid : int;
  gid : int;
}

type snapshot = { files : file Path_map.t; dirs : string list }

let empty_snapshot = { files = Path_map.empty; dirs = [] }

let has_nul text =
  let rec loop i =
    i < String.length text && (Char.equal text.[i] '\000' || loop (i + 1))
  in
  loop 0

let root_error root reason = error (Error.Invalid_root { root; reason })
let path_error path reason = error (Error.Invalid_path { path; reason })
let io_error path reason = error (Error.Io { path; reason })
let unix_error path ex = io_error path (Printexc.to_string ex)

let backend_unavailable backend reason =
  error (Error.Backend_unavailable { backend; reason })

let stat_kind stats =
  match stats.Unix.st_kind with
  | Unix.S_DIR -> Directory
  | Unix.S_REG -> Regular_file
  | Unix.S_LNK -> Symlink
  | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Other

let file_of_stats stats =
  {
    kind = stat_kind stats;
    dev = stats.Unix.st_dev;
    ino = stats.Unix.st_ino;
    size = Int64.of_int stats.Unix.st_size;
    mtime = stats.Unix.st_mtime;
    ctime = stats.Unix.st_ctime;
    perm = stats.Unix.st_perm;
    uid = stats.Unix.st_uid;
    gid = stats.Unix.st_gid;
  }

let same_identity a b =
  Int.equal a.dev b.dev && Int.equal a.ino b.ino && a.kind = b.kind

let same_owner_and_perm a b =
  Int.equal a.perm b.perm && Int.equal a.uid b.uid && Int.equal a.gid b.gid

let same_file a b =
  match (a.kind, b.kind) with
  | Directory, Directory -> same_identity a b && same_owner_and_perm a b
  | (Regular_file | Symlink | Other), (Regular_file | Symlink | Other) ->
      same_identity a b && same_owner_and_perm a b && Int64.equal a.size b.size
      && Float.equal a.mtime b.mtime
      && Float.equal a.ctime b.ctime
  | (Directory | Regular_file | Symlink | Other), _ -> false

let read_dir path =
  let dir = Unix.opendir path in
  Fun.protect
    ~finally:(fun () -> Unix.closedir dir)
    (fun () ->
      let rec loop acc =
        match Unix.readdir dir with
        | "." | ".." -> loop acc
        | name -> loop (name :: acc)
        | exception End_of_file -> List.sort String.compare acc
      in
      loop [])

let relative_child parent name =
  match Spice_path.Rel.add_component parent name with
  | Error error -> path_error name (Spice_path.Error.message error)
  | Ok child -> Ok child

let add_file relative file snapshot =
  { snapshot with files = Path_map.add relative file snapshot.files }

let add_dir absolute snapshot =
  { snapshot with dirs = absolute :: snapshot.dirs }

let rec scan_entry ~ignore absolute relative snapshot =
  if ignore relative then Ok snapshot
  else
    match Unix.lstat absolute with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok snapshot
    | exception ex -> unix_error absolute ex
    | stats -> (
        let file = file_of_stats stats in
        let snapshot = add_file relative file snapshot in
        match file.kind with
        | Directory ->
            scan_dir ~ignore absolute relative (add_dir absolute snapshot)
        | Regular_file | Symlink | Other -> Ok snapshot)

and scan_dir ~ignore absolute relative snapshot =
  let names =
    match read_dir absolute with
    | names -> Ok names
    | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> Ok []
    | exception ex -> unix_error absolute ex
  in
  match names with
  | Error _ as error -> error
  | Ok names ->
      let rec loop snapshot = function
        | [] -> Ok snapshot
        | name :: names -> (
            match relative_child relative name with
            | Error _ as error -> error
            | Ok child_relative -> (
                let child_absolute = Filename.concat absolute name in
                match
                  scan_entry ~ignore child_absolute child_relative snapshot
                with
                | Error _ as error -> error
                | Ok snapshot -> loop snapshot names))
      in
      loop snapshot names

let scan ~root ~ignore =
  scan_entry ~ignore root Spice_path.Rel.root empty_snapshot

let scan_in_systhread ~root ~ignore =
  Eio_unix.run_in_systhread ~label:"spice-file-watcher-scan" (fun () ->
      scan ~root ~ignore)

let diff before after =
  let add_event path kind acc = { Event.path; kind } :: acc in
  let acc =
    Path_map.fold
      (fun path previous acc ->
        match Path_map.find_opt path after with
        | None -> add_event path Event.Deleted acc
        | Some current ->
            if same_file previous current then acc
            else add_event path Event.Changed acc)
      before []
  in
  let acc =
    Path_map.fold
      (fun path _ acc ->
        if Path_map.mem path before then acc
        else add_event path Event.Created acc)
      after acc
  in
  List.sort Event.compare acc

module Signal = struct
  type t = {
    mutex : Mutex.t;
    condition : Condition.t;
    mutable pending : bool;
    mutable closed : bool;
    mutable terminated : string option;
  }

  let make () =
    {
      mutex = Mutex.create ();
      condition = Condition.create ();
      pending = false;
      closed = false;
      terminated = None;
    }

  let notify t =
    Mutex.protect t.mutex (fun () ->
        if (not t.closed) && Option.is_none t.terminated then begin
          t.pending <- true;
          Condition.signal t.condition
        end)

  let drain t = Mutex.protect t.mutex (fun () -> t.pending <- false)

  let close t =
    Mutex.protect t.mutex (fun () ->
        if not t.closed then begin
          t.closed <- true;
          t.pending <- false;
          Condition.broadcast t.condition
        end)

  let terminate t reason =
    Mutex.protect t.mutex (fun () ->
        if (not t.closed) && Option.is_none t.terminated then begin
          t.terminated <- Some reason;
          t.pending <- false;
          Condition.broadcast t.condition
        end)

  let await t =
    Eio_unix.run_in_systhread ~label:"spice-file-watcher-await" (fun () ->
        Mutex.lock t.mutex;
        Fun.protect
          ~finally:(fun () -> Mutex.unlock t.mutex)
          (fun () ->
            while
              (not t.pending) && (not t.closed) && Option.is_none t.terminated
            do
              Condition.wait t.condition t.mutex
            done;
            match t.terminated with
            | Some reason -> `Terminated reason
            | None when t.closed -> `Closed
            | None ->
                t.pending <- false;
                `Wakeup))
end

module Native = struct
  type t = {
    wakeup : Signal.t;
    rebuild : string list -> (unit, string) result;
    close : unit -> unit;
  }

  let await t = Signal.await t.wakeup
  let drain t = Signal.drain t.wakeup
  let poke t = Signal.notify t.wakeup
  let rebuild t dirs = t.rebuild dirs
  let close t = t.close ()

  module Inotify = struct
    external supported : unit -> bool = "spice_file_watcher_inotify_supported"

    external create : unit -> Unix.file_descr
      = "spice_file_watcher_inotify_create"

    external add_watch : Unix.file_descr -> string -> int
      = "spice_file_watcher_inotify_add_watch"

    external rm_watch : Unix.file_descr -> int -> unit
      = "spice_file_watcher_inotify_rm_watch"

    external read : Unix.file_descr -> unit = "spice_file_watcher_inotify_read"

    type state = {
      fd : Unix.file_descr;
      signal : Signal.t;
      mutex : Mutex.t;
      mutable watches : int list;
      mutable closed : bool;
    }

    let is_closed state = Mutex.protect state.mutex (fun () -> state.closed)

    let clear_watches state =
      List.iter
        (fun watch ->
          match rm_watch state.fd watch with () -> () | exception _ -> ())
        state.watches;
      state.watches <- []

    let rebuild state dirs =
      Mutex.protect state.mutex (fun () ->
          if state.closed then Error "watcher is closed"
          else begin
            clear_watches state;
            let rec loop = function
              | [] -> Ok ()
              | dir :: dirs -> (
                  match add_watch state.fd dir with
                  | watch ->
                      state.watches <- watch :: state.watches;
                      loop dirs
                  | exception
                      Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) ->
                      loop dirs
                  | exception ex -> Error (Printexc.to_string ex))
            in
            loop dirs
          end)

    let close_state state =
      let should_close =
        Mutex.protect state.mutex (fun () ->
            if state.closed then false
            else begin
              state.closed <- true;
              true
            end)
      in
      if should_close then begin
        Signal.close state.signal;
        match Unix.close state.fd with
        | () -> ()
        | exception Unix.Unix_error _ -> ()
      end

    let make ~sw ~dirs =
      if not (supported ()) then None
      else
        match create () with
        | exception _ -> None
        | fd ->
            let signal = Signal.make () in
            let state =
              {
                fd;
                signal;
                mutex = Mutex.create ();
                watches = [];
                closed = false;
              }
            in
            begin match rebuild state dirs with
            | Ok () ->
                Eio.Fiber.fork_daemon ~sw (fun () ->
                    let rec loop () =
                      if is_closed state then `Stop_daemon
                      else
                        match
                          Eio_unix.run_in_systhread
                            ~label:"spice-file-watcher-inotify-read" (fun () ->
                              read state.fd)
                        with
                        | () ->
                            Signal.notify signal;
                            loop ()
                        | exception Unix.Unix_error (Unix.EBADF, _, _) ->
                            `Stop_daemon
                        | exception ex ->
                            Signal.terminate signal (Printexc.to_string ex);
                            `Stop_daemon
                    in
                    loop ());
                Some
                  ({
                     wakeup = signal;
                     rebuild = rebuild state;
                     close = (fun () -> close_state state);
                   }
                    : t)
            | Error _ ->
                close_state state;
                None
            end
  end

  module Fsevents = struct
    type raw

    external available : unit -> bool = "spice_file_watcher_fsevents_available"

    external create : string -> float -> (unit -> unit) -> raw
      = "spice_file_watcher_fsevents_create"

    external stop : raw -> unit = "spice_file_watcher_fsevents_stop"

    let make ~root ~latency =
      if not (available ()) then None
      else
        let signal = Signal.make () in
        match create root latency (fun () -> Signal.notify signal) with
        | exception _ -> None
        | raw ->
            let closed = ref false in
            let close () =
              if not !closed then begin
                closed := true;
                Signal.close signal;
                match stop raw with () -> () | exception _ -> ()
              end
            in
            Some
              ({ wakeup = signal; rebuild = (fun _dirs -> Ok ()); close } : t)
  end

  let make ~sw ~root ~dirs ~latency =
    match Fsevents.make ~root ~latency with
    | Some _ as native -> native
    | None -> Inotify.make ~sw ~dirs
end

type selected_backend = Polling | Native of Native.t
type wakeup = Wakeup | Timeout | Closed | Native_terminated of string

type t = {
  root : string;
  sleep : float -> unit;
  polling_interval : float;
  settle_delay : float;
  ignore : Spice_path.Rel.t -> bool;
  backend_preference : backend_preference;
  close_mutex : Mutex.t;
  wakeups : wakeup Eio.Stream.t;
  mutable snapshot : snapshot;
  mutable selected_backend : selected_backend;
  mutable closed : bool;
}

let is_closed t = Mutex.protect t.close_mutex (fun () -> t.closed)

let mark_closed t =
  Mutex.protect t.close_mutex (fun () ->
      if t.closed then false
      else begin
        t.closed <- true;
        true
      end)

let root t = t.root

let backend t =
  match t.selected_backend with Polling -> `Polling | Native _ -> `Native

let close t =
  if mark_closed t then begin
    Log.info (fun m -> m "watcher stopped root=%s" t.root);
    Eio.Stream.add t.wakeups Closed;
    match t.selected_backend with
    | Polling -> ()
    | Native native -> Native.close native
  end

let validate_root root =
  if String.equal root "" || has_nul root then
    root_error root "root must not be empty or contain NUL"
  else if Filename.is_relative root then root_error root "root must be absolute"
  else
    match Unix.realpath root with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        root_error root "root does not exist"
    | exception ex -> unix_error root ex
    | real_root -> (
        match Spice_path.Abs.of_string real_root with
        | Error e -> root_error root (Spice_path.Error.message e)
        | Ok abs -> (
            let root = Spice_path.Abs.to_string abs in
            match Unix.stat root with
            | exception ex -> unix_error root ex
            | stats ->
                if not (stats.Unix.st_kind = Unix.S_DIR) then
                  root_error root "root is not a directory"
                else Ok root))

let check_timing ~caller name value =
  let finite =
    match classify_float value with
    | FP_nan | FP_infinite -> false
    | FP_normal | FP_subnormal | FP_zero -> true
  in
  if not (value > 0.0 && finite) then
    invalid_arg
      (Printf.sprintf "Spice_fswatch.%s: %s=%g must be positive and finite"
         caller name value)

let make ~sw ~clock ?(backend = `Best) ?(poll_interval = 0.25)
    ?(settle_delay = 0.05) ?(ignore = fun _ -> false) ~root () =
  check_timing ~caller:"make" "poll_interval" poll_interval;
  check_timing ~caller:"make" "settle_delay" settle_delay;
  let initialized =
    Eio_unix.run_in_systhread ~label:"spice-file-watcher-init" (fun () ->
        match validate_root root with
        | Error _ as error -> error
        | Ok root -> (
            match scan ~root ~ignore with
            | Error _ as error -> error
            | Ok snapshot -> Ok (root, snapshot)))
  in
  match initialized with
  | Error _ as error -> error
  | Ok (root, snapshot) -> (
      let selected_backend =
        match backend with
        | `Polling -> Ok Polling
        | `Best -> (
            match
              Native.make ~sw ~root ~dirs:snapshot.dirs ~latency:settle_delay
            with
            | None -> Ok Polling
            | Some native -> Ok (Native native))
        | `Native -> (
            match
              Native.make ~sw ~root ~dirs:snapshot.dirs ~latency:settle_delay
            with
            | None -> backend_unavailable "native" "no supported native backend"
            | Some native -> Ok (Native native))
      in
      match selected_backend with
      | Error _ as error -> error
      | Ok selected_backend ->
          let t =
            {
              root;
              sleep = Eio.Time.sleep clock;
              polling_interval = poll_interval;
              settle_delay;
              ignore;
              backend_preference = backend;
              close_mutex = Mutex.create ();
              wakeups = Eio.Stream.create max_int;
              snapshot;
              selected_backend;
              closed = false;
            }
          in
          (* The native backends block a dedicated fiber in an
                     uncancellable [run_in_systhread] ([Condition.wait] for
                     FSEvents, [read] for inotify) that only [close] wakes.
                     Closing from [Switch.on_release] deadlocks: a switch runs
                     its release handlers only once every fiber has finished,
                     but the await fiber cannot finish until [close] wakes it,
                     and [close] is the release handler waiting on it. Break the
                     cycle by closing the moment the switch is cancelled, from a
                     daemon that observes cancellation itself; the systhread then
                     returns and the await fiber exits, letting teardown finish.
                     [close] is idempotent, so an explicit close still works. *)
          Eio.Fiber.fork_daemon ~sw (fun () ->
              (try Eio.Fiber.await_cancel () with Eio.Cancel.Cancelled _ -> ());
              Eio.Cancel.protect (fun () -> close t);
              `Stop_daemon);
          begin match selected_backend with
          | Polling -> ()
          | Native native ->
              Eio.Fiber.fork_daemon ~sw (fun () ->
                  let rec loop () =
                    match Native.await native with
                    | `Wakeup ->
                        Eio.Stream.add t.wakeups Wakeup;
                        loop ()
                    | `Closed ->
                        Eio.Stream.add t.wakeups Closed;
                        `Stop_daemon
                    | `Terminated reason ->
                        Eio.Stream.add t.wakeups (Native_terminated reason);
                        `Stop_daemon
                  in
                  loop ());
              Native.poke native
          end;
          Log.info (fun m ->
              m "watcher established root=%s backend=%s" root
                (match selected_backend with
                | Polling -> "polling"
                | Native _ -> "native"));
          Ok t)

let handle_native_rebuild_result t native = function
  | Ok () -> Ok ()
  | Error reason -> (
      Native.close native;
      match t.backend_preference with
      | `Best ->
          Log.warn (fun m ->
              m "native backend rebuild failed, falling back to polling: %s"
                reason);
          t.selected_backend <- Polling;
          Ok ()
      | `Native -> backend_unavailable "native" reason
      | `Polling -> Ok ())

let handle_native_termination t native reason =
  Native.close native;
  match t.backend_preference with
  | `Best ->
      Log.warn (fun m ->
          m "native backend terminated, falling back to polling: %s" reason);
      t.selected_backend <- Polling;
      Ok ()
  | `Native -> backend_unavailable "native" reason
  | `Polling -> Ok ()

let set_snapshot t snapshot =
  let events = diff t.snapshot.files snapshot.files in
  t.snapshot <- snapshot;
  match t.selected_backend with
  | Polling -> Ok events
  | Native native -> (
      match Native.rebuild native snapshot.dirs with
      | Ok () -> Ok events
      | Error _ as rebuild_error -> (
          match handle_native_rebuild_result t native rebuild_error with
          | Ok () -> Ok events
          | Error _ as error -> error))

let poll t =
  if is_closed t then Ok []
  else
    match scan_in_systhread ~root:t.root ~ignore:t.ignore with
    | Error _ as error -> error
    | Ok snapshot -> (
        match set_snapshot t snapshot with
        | Error _ as error -> error
        | Ok events ->
            (match events with
            | [] -> ()
            | _ ->
                Log.debug (fun m ->
                    m "detected %d filesystem change(s)" (List.length events)));
            Ok events)

let reset t =
  if is_closed t then Ok ()
  else begin
    begin match t.selected_backend with
    | Polling -> ()
    | Native native -> Native.drain native
    end;
    match scan_in_systhread ~root:t.root ~ignore:t.ignore with
    | Error _ as error -> error
    | Ok snapshot -> (
        t.snapshot <- snapshot;
        match t.selected_backend with
        | Polling -> Ok ()
        | Native native -> (
            match Native.rebuild native snapshot.dirs with
            | Ok () -> Ok ()
            | Error _ as rebuild_error ->
                handle_native_rebuild_result t native rebuild_error))
  end

let next t =
  let wait_for_wakeup interval =
    match Eio.Stream.take_nonblocking t.wakeups with
    | Some wakeup -> wakeup
    | None ->
        Eio.Fiber.first
          (fun () -> Eio.Stream.take t.wakeups)
          (fun () ->
            t.sleep interval;
            Timeout)
  in
  let rec loop () =
    if is_closed t then Ok None
    else
      match t.selected_backend with
      | Polling -> (
          match wait_for_wakeup t.polling_interval with
          | Closed when is_closed t -> Ok None
          | Native_terminated _ | Wakeup | Timeout -> (
              match poll t with
              | Error _ as error -> error
              | Ok [] -> loop ()
              | Ok events -> Ok (Some events))
          | Closed -> loop ())
      | Native native -> (
          match wait_for_wakeup t.polling_interval with
          | Closed when is_closed t -> Ok None
          | Closed -> loop ()
          | Native_terminated reason -> (
              match handle_native_termination t native reason with
              | Error _ as error -> error
              | Ok () -> (
                  match poll t with
                  | Error _ as error -> error
                  | Ok [] -> loop ()
                  | Ok events -> Ok (Some events)))
          | Timeout -> (
              match poll t with
              | Error _ as error -> error
              | Ok [] -> loop ()
              | Ok events -> Ok (Some events))
          | Wakeup -> (
              t.sleep t.settle_delay;
              Native.drain native;
              match poll t with
              | Error _ as error -> error
              | Ok [] -> loop ()
              | Ok events -> Ok (Some events)))
  in
  loop ()

let iter t ~f =
  let rec loop () =
    match next t with
    | Error _ as error -> error
    | Ok None -> Ok ()
    | Ok (Some events) ->
        f events;
        loop ()
  in
  loop ()

let watch ~sw ~clock ?backend ?(poll_interval = 0.25) ?(settle_delay = 0.05)
    ?ignore ?on_ready ~on_error ~root ~f () =
  check_timing ~caller:"watch" "poll_interval" poll_interval;
  check_timing ~caller:"watch" "settle_delay" settle_delay;
  (* Fork before [make] so construction stays non-blocking, then close under
     the mutex if a stop arrived while [make] was scanning. This is the same
     start/close-race guard [next]'s [close] contract relies on. *)
  let watcher = ref None and stopped = ref false in
  let mutex = Eio.Mutex.create () in
  let stop () =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
        stopped := true;
        Option.iter close !watcher)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Switch.run ~name:"spice-fswatch" (fun watch_sw ->
          match
            make ~sw:watch_sw ~clock ?backend ~poll_interval ~settle_delay
              ?ignore ~root ()
          with
          | Error e -> on_error e
          | Ok w -> (
              let ready =
                Eio.Mutex.use_rw ~protect:true mutex (fun () ->
                    watcher := Some w;
                    if !stopped then `Stopped else `Ready)
              in
              match ready with
              | `Stopped -> close w
              | `Ready -> (
                  Option.iter (fun on_ready -> on_ready w) on_ready;
                  match iter w ~f with Ok () -> () | Error e -> on_error e)));
      `Stop_daemon);
  stop
