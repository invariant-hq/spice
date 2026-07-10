(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.tools.process" ~doc:"Subprocess execution"

module Log = (val Logs.src_log log_src : Logs.LOG)

type status =
  | Exited of int
  | Signaled of int
  | Cancelled
  | Output_exceeded of string
  | Failed of string
  | Refused of Spice_sandbox.Error.t

type result = { status : status; stdout : string; stderr : string }

type captured =
  | Complete of string
  | Truncated of { head : string; tail : string; omitted_bytes : int }

type shell_status =
  | Shell_exited of int
  | Shell_signaled of int
  | Shell_timed_out of { timeout_ms : int }
  | Shell_cancelled
  | Shell_failed_to_start of string
  | Shell_refused of Spice_sandbox.Error.t

type shell_result = {
  shell_status : shell_status;
  shell_stdout : captured;
  shell_stderr : captured;
  shell_duration_ms : int;
}

let split_env binding =
  match String.index_opt binding '=' with
  | None -> (binding, "")
  | Some index ->
      ( String.sub binding 0 index,
        String.sub binding (index + 1) (String.length binding - index - 1) )

let environment_array bindings =
  bindings
  |> List.map (fun (name, value) -> name ^ "=" ^ value)
  |> Array.of_list

let prepare ~sandbox ~env = function
  | [] -> Error (Spice_sandbox.Error.invalid_request "process argv is empty")
  | program :: args ->
      let argv = Spice_sandbox.Argv.make ~program args in
      let env = Array.to_list env |> List.map split_env in
      Result.map
        (fun spawn ->
          ( Spice_sandbox.Spawn.argv spawn |> Spice_sandbox.Argv.to_list,
            Spice_sandbox.Spawn.env spawn |> environment_array ))
        (Spice_sandbox.spawn sandbox ~argv ~env)

let default_stdout_limit = 1024 * 1024
let default_stderr_limit = 64 * 1024
let close fd = try Unix.close fd with Unix.Unix_error _ -> ()

let waitpid_nointr flags pid =
  let rec loop () =
    match Unix.waitpid flags pid with
    | result -> result
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()

let set_nonblock fd = try Unix.set_nonblock fd with Unix.Unix_error _ -> ()

let read_fd ~stream ~max_bytes fd buffer bytes =
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
      let remaining = max_bytes - Buffer.length buffer in
      if n > remaining then begin
        if remaining > 0 then Buffer.add_subbytes buffer bytes 0 remaining;
        `Exceeded stream
      end
      else begin
        Buffer.add_subbytes buffer bytes 0 n;
        `Open
      end
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> `Open
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> `Open
  | exception Unix.Unix_error (error, fn, arg) ->
      `Failed (Unix.error_message error ^ " in " ^ fn ^ "(" ^ arg ^ ")")

let status_of_unix = function
  | Unix.WEXITED code -> Exited code
  | Unix.WSIGNALED signal -> Signaled signal
  | Unix.WSTOPPED signal -> Signaled signal

let kill pid signal = try Unix.kill pid signal with Unix.Unix_error _ -> ()

let unix_error_message error fn arg =
  Unix.error_message error ^ " in " ^ fn ^ "(" ^ arg ^ ")"

let validate_limit name limit =
  if limit < 0 then invalid_arg (name ^ " must be non-negative")

module Head_tail = struct
  type t = {
    max_bytes : int;
    head : Buffer.t;
    mutable tail : string;
    mutable omitted_bytes : int;
  }

  let make max_bytes =
    validate_limit "max_output_bytes" max_bytes;
    {
      max_bytes;
      head = Buffer.create (min max_bytes 4096);
      tail = "";
      omitted_bytes = 0;
    }

  let add_tail t bytes offset len =
    if len = 0 then ()
    else
      let tail_bytes = t.max_bytes - (t.max_bytes / 2) in
      if tail_bytes = 0 then t.omitted_bytes <- t.omitted_bytes + len
      else
        let current = String.length t.tail in
        let total = current + len in
        if total <= tail_bytes then
          t.tail <- t.tail ^ Bytes.sub_string bytes offset len
        else if len >= tail_bytes then begin
          t.omitted_bytes <- t.omitted_bytes + total - tail_bytes;
          t.tail <-
            Bytes.sub_string bytes (offset + len - tail_bytes) tail_bytes
        end
        else begin
          let keep_current = tail_bytes - len in
          t.omitted_bytes <- t.omitted_bytes + current - keep_current;
          t.tail <-
            String.sub t.tail (current - keep_current) keep_current
            ^ Bytes.sub_string bytes offset len
        end

  let add t bytes offset len =
    if len = 0 then ()
    else if t.max_bytes = 0 then t.omitted_bytes <- t.omitted_bytes + len
    else
      let head_bytes = t.max_bytes / 2 in
      let head_len = Buffer.length t.head in
      if head_len < head_bytes then begin
        let keep = min len (head_bytes - head_len) in
        Buffer.add_subbytes t.head bytes offset keep;
        add_tail t bytes (offset + keep) (len - keep)
      end
      else add_tail t bytes offset len

  let captured t =
    let head = Buffer.contents t.head in
    if t.omitted_bytes = 0 then Complete (head ^ t.tail)
    else Truncated { head; tail = t.tail; omitted_bytes = t.omitted_bytes }
end

let elapsed_ms start = int_of_float ((Unix.gettimeofday () -. start) *. 1000.)

let read_bounded output fd bytes =
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
      Head_tail.add output bytes 0 n;
      `Open
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> `Open
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> `Open
  | exception Unix.Unix_error (error, fn, arg) ->
      `Failed (unix_error_message error fn arg)

let read_plain buffer fd bytes =
  match Unix.read fd bytes 0 (Bytes.length bytes) with
  | 0 -> `Closed
  | n ->
      Buffer.add_subbytes buffer bytes 0 n;
      `Open
  | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> `Open
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> `Open
  | exception Unix.Unix_error (error, fn, arg) ->
      `Failed (unix_error_message error fn arg)

let kill_process_group pid signal =
  try Unix.kill (-pid) signal with Unix.Unix_error _ -> kill pid signal

let terminate_process_group pid =
  kill_process_group pid Sys.sigterm;
  Unix.sleepf 0.2;
  kill_process_group pid Sys.sigkill

let write_all fd text =
  let bytes = Bytes.of_string text in
  let rec loop offset =
    if offset < Bytes.length bytes then
      match Unix.write fd bytes offset (Bytes.length bytes - offset) with
      | 0 -> ()
      | n -> loop (offset + n)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
      | exception Unix.Unix_error _ -> ()
  in
  loop 0

let child_exec_error error fn arg = unix_error_message error fn arg

let fork_exec ~cwd ~env ~stdin ~stdout ~stderr ~exec_error argv =
  match argv with
  | [] -> Error "empty argv"
  | prog :: _ -> (
      match Unix.fork () with
      | exception Unix.Unix_error (error, fn, arg) ->
          Error (unix_error_message error fn arg)
      | 0 ->
          begin try ignore (Unix.setsid ()) with Unix.Unix_error _ -> ()
          end;
          begin try
            Unix.chdir cwd;
            Unix.dup2 stdin Unix.stdin;
            Unix.dup2 stdout Unix.stdout;
            Unix.dup2 stderr Unix.stderr;
            Unix.execvpe prog (Array.of_list argv) env
          with
          | Unix.Unix_error (error, fn, arg) ->
              write_all exec_error (child_exec_error error fn arg);
              Unix._exit 127
          | exn ->
              write_all exec_error (Printexc.to_string exn);
              Unix._exit 127
          end
      | pid -> Ok pid)

let run_shell_blocking ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin ~cancelled
    argv =
  if String.equal cwd "" then invalid_arg "cwd must not be empty";
  if timeout_ms <= 0 then invalid_arg "timeout_ms must be positive";
  validate_limit "max_output_bytes" max_output_bytes;
  let start = Unix.gettimeofday () in
  let stdout = Head_tail.make max_output_bytes in
  let stderr = Head_tail.make max_output_bytes in
  let finish shell_status =
    let result =
      {
        shell_status;
        shell_stdout = Head_tail.captured stdout;
        shell_stderr = Head_tail.captured stderr;
        shell_duration_ms = elapsed_ms start;
      }
    in
    Log.debug (fun m ->
        m "shell finished status=%s duration_ms=%d"
          (match shell_status with
          | Shell_exited code -> Printf.sprintf "exited(%d)" code
          | Shell_signaled signal -> Printf.sprintf "signaled(%d)" signal
          | Shell_timed_out { timeout_ms } ->
              Printf.sprintf "timed_out(%d)" timeout_ms
          | Shell_cancelled -> "cancelled"
          | Shell_failed_to_start _ -> "failed_to_start"
          | Shell_refused _ -> "refused")
          result.shell_duration_ms);
    result
  in
  let open_fds = ref [] in
  let track fd =
    open_fds := fd :: !open_fds;
    fd
  in
  let untrack fd =
    open_fds := List.filter (fun candidate -> candidate <> fd) !open_fds
  in
  let close_tracked fd =
    untrack fd;
    close fd
  in
  let cleanup () =
    List.iter close !open_fds;
    open_fds := []
  in
  let setup =
    try
      let child_stdin, parent_stdin =
        match stdin with
        | None -> (track (Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0), None)
        | Some _ ->
            let stdin_r, stdin_w = Unix.pipe () in
            Unix.set_close_on_exec stdin_w;
            (track stdin_r, Some (track stdin_w))
      in
      let stdout_r, stdout_w = Unix.pipe () in
      let stdout_r = track stdout_r in
      let stdout_w = track stdout_w in
      let stderr_r, stderr_w = Unix.pipe () in
      let stderr_r = track stderr_r in
      let stderr_w = track stderr_w in
      let exec_r, exec_w = Unix.pipe () in
      let exec_r = track exec_r in
      let exec_w = track exec_w in
      Unix.set_close_on_exec exec_w;
      Ok
        ( child_stdin,
          parent_stdin,
          stdout_r,
          stdout_w,
          stderr_r,
          stderr_w,
          exec_r,
          exec_w )
    with
    | Unix.Unix_error (error, fn, arg) ->
        cleanup ();
        Error (unix_error_message error fn arg)
    | exn ->
        cleanup ();
        Error (Printexc.to_string exn)
  in
  match setup with
  | Error message -> finish (Shell_failed_to_start message)
  | Ok
      ( child_stdin,
        parent_stdin,
        stdout_r,
        stdout_w,
        stderr_r,
        stderr_w,
        exec_r,
        exec_w ) -> (
      let child =
        fork_exec ~cwd ~env ~stdin:child_stdin ~stdout:stdout_w ~stderr:stderr_w
          ~exec_error:exec_w argv
      in
      close_tracked child_stdin;
      close_tracked stdout_w;
      close_tracked stderr_w;
      close_tracked exec_w;
      Option.iter set_nonblock parent_stdin;
      set_nonblock stdout_r;
      set_nonblock stderr_r;
      set_nonblock exec_r;
      match child with
      | Error message ->
          cleanup ();
          finish (Shell_failed_to_start message)
      | Ok pid -> (
          Log.debug (fun m ->
              m "spawn program=%s argc=%d timeout_ms=%d"
                (match argv with program :: _ -> program | [] -> "?")
                (List.length argv) timeout_ms);
          let bytes = Bytes.create 8192 in
          let exec_error = Buffer.create 128 in
          let read_failure = ref None in
          let stdin_bytes = Option.map Bytes.of_string stdin in
          let stdin_offset = ref 0 in
          let stdin_fd = ref parent_stdin in
          let close_stdin () =
            match !stdin_fd with
            | None -> ()
            | Some fd ->
                stdin_fd := None;
                close_tracked fd
          in
          let write_stdin () =
            match (stdin_bytes, !stdin_fd) with
            | Some bytes, Some fd -> (
                if !stdin_offset >= Bytes.length bytes then close_stdin ()
                else
                  match
                    Unix.write fd bytes !stdin_offset
                      (Bytes.length bytes - !stdin_offset)
                  with
                  | 0 -> ()
                  | n ->
                      stdin_offset := !stdin_offset + n;
                      if !stdin_offset >= Bytes.length bytes then close_stdin ()
                  | exception
                      Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
                    ->
                      ()
                  | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
                  | exception Unix.Unix_error (Unix.EPIPE, _, _) ->
                      close_stdin ()
                  | exception Unix.Unix_error _ -> close_stdin ())
            | None, Some _ -> close_stdin ()
            | Some _, None | None, None -> ()
          in
          let read_open_fd fd =
            let result =
              if fd = stdout_r then read_bounded stdout fd bytes
              else if fd = stderr_r then read_bounded stderr fd bytes
              else read_plain exec_error fd bytes
            in
            match result with
            | `Open -> true
            | `Closed ->
                close_tracked fd;
                false
            | `Failed message ->
                read_failure := Some message;
                close_tracked fd;
                false
          in
          let poll ?(timeout = 0.02) open_fds =
            let write_fds =
              match !stdin_fd with None -> [] | Some fd -> [ fd ]
            in
            match Unix.select open_fds write_fds [] timeout with
            | readable, writable, _ ->
                begin match !stdin_fd with
                | Some fd when List.mem fd writable -> write_stdin ()
                | Some _ | None -> ()
                end;
                List.filter
                  (fun fd -> (not (List.mem fd readable)) || read_open_fd fd)
                  open_fds
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> open_fds
          in
          let rec drain_until deadline status open_fds =
            match open_fds with
            | [] -> status
            | fds ->
                let now = Unix.gettimeofday () in
                if now >= deadline then status
                else
                  let timeout = min 0.02 (deadline -. now) in
                  drain_until deadline status (poll ~timeout fds)
          in
          let drain status open_fds =
            drain_until (Unix.gettimeofday () +. 0.2) status open_fds
          in
          let rec wait open_fds =
            if cancelled () then begin
              Log.debug (fun m ->
                  m "cancelled, terminating process group pid=%d" pid);
              close_stdin ();
              terminate_process_group pid;
              ignore (waitpid_nointr [] pid);
              drain Shell_cancelled open_fds
            end
            else if elapsed_ms start >= timeout_ms then begin
              Log.warn (fun m ->
                  m "timeout after %dms, terminating process group pid=%d"
                    timeout_ms pid);
              close_stdin ();
              terminate_process_group pid;
              ignore (waitpid_nointr [] pid);
              drain (Shell_timed_out { timeout_ms }) open_fds
            end
            else
              let open_fds = poll open_fds in
              match waitpid_nointr [ Unix.WNOHANG ] pid with
              | 0, _ -> wait open_fds
              | _, status ->
                  let status =
                    match status with
                    | Unix.WEXITED _ when Buffer.length exec_error > 0 ->
                        Shell_failed_to_start (Buffer.contents exec_error)
                    | Unix.WEXITED code -> Shell_exited code
                    | Unix.WSIGNALED signal -> Shell_signaled signal
                    | Unix.WSTOPPED signal -> Shell_signaled signal
                  in
                  close_stdin ();
                  drain status open_fds
          in
          let status = wait [ stdout_r; stderr_r; exec_r ] in
          cleanup ();
          match !read_failure with
          | None -> finish status
          | Some message -> finish (Shell_failed_to_start message)))

let run_blocking ?(stdout_limit = default_stdout_limit)
    ?(stderr_limit = default_stderr_limit) ~env ~cancelled argv =
  validate_limit "stdout_limit" stdout_limit;
  validate_limit "stderr_limit" stderr_limit;
  match argv with
  | [] -> { status = Failed "empty argv"; stdout = ""; stderr = "" }
  | prog :: _ -> (
      let open_fds = ref [] in
      let track fd =
        open_fds := fd :: !open_fds;
        fd
      in
      let untrack fd =
        open_fds := List.filter (fun candidate -> candidate <> fd) !open_fds
      in
      let close_tracked fd =
        untrack fd;
        close fd
      in
      let cleanup () =
        List.iter close !open_fds;
        open_fds := []
      in
      let setup =
        try
          let stdin = track (Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0) in
          let stdout_r, stdout_w = Unix.pipe () in
          let stdout_r = track stdout_r in
          let stdout_w = track stdout_w in
          let stderr_r, stderr_w = Unix.pipe () in
          let stderr_r = track stderr_r in
          let stderr_w = track stderr_w in
          Ok (stdin, stdout_r, stdout_w, stderr_r, stderr_w)
        with
        | Unix.Unix_error (error, fn, arg) ->
            cleanup ();
            Error (unix_error_message error fn arg)
        | exn ->
            cleanup ();
            Error (Printexc.to_string exn)
      in
      let stdout = Buffer.create 4096 in
      let stderr = Buffer.create 1024 in
      let bytes = Bytes.create 8192 in
      match setup with
      | Error message -> { status = Failed message; stdout = ""; stderr = "" }
      | Ok (stdin, stdout_r, stdout_w, stderr_r, stderr_w) -> (
          let child =
            try
              let argv = Array.of_list argv in
              Ok (Unix.create_process_env prog argv env stdin stdout_w stderr_w)
            with
            | Unix.Unix_error (error, fn, arg) ->
                Error (unix_error_message error fn arg)
            | exn -> Error (Printexc.to_string exn)
          in
          close_tracked stdin;
          close_tracked stdout_w;
          close_tracked stderr_w;
          set_nonblock stdout_r;
          set_nonblock stderr_r;
          let exceeded = ref None in
          let read_failure = ref None in
          let read_open_fd fd =
            let buffer = if fd = stdout_r then stdout else stderr in
            let stream, max_bytes =
              if fd = stdout_r then ("stdout", stdout_limit)
              else ("stderr", stderr_limit)
            in
            match read_fd ~stream ~max_bytes fd buffer bytes with
            | `Open -> true
            | `Closed ->
                close_tracked fd;
                false
            | `Exceeded stream ->
                exceeded := Some stream;
                close_tracked fd;
                false
            | `Failed message ->
                read_failure := Some message;
                Buffer.add_string stderr message;
                Buffer.add_char stderr '\n';
                close_tracked fd;
                false
          in
          let poll ?(timeout = 0.02) open_fds =
            match Unix.select open_fds [] [] timeout with
            | readable, _, _ ->
                List.filter
                  (fun fd -> (not (List.mem fd readable)) || read_open_fd fd)
                  open_fds
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> open_fds
          in
          match child with
          | Error message ->
              cleanup ();
              { status = Failed message; stdout = ""; stderr = "" }
          | Ok pid ->
              Log.debug (fun m ->
                  m "spawn program=%s argc=%d" prog (List.length argv));
              let rec drain_until deadline status open_fds =
                match open_fds with
                | [] -> status
                | fds ->
                    let now = Unix.gettimeofday () in
                    if now >= deadline then status
                    else
                      let timeout = min 0.02 (deadline -. now) in
                      drain_until deadline status (poll ~timeout fds)
              in
              let drain status open_fds =
                drain_until (Unix.gettimeofday () +. 0.2) status open_fds
              in
              let rec wait open_fds =
                match !exceeded with
                | Some stream ->
                    Log.warn (fun m ->
                        m "output exceeded limit on %s, terminating pid=%d"
                          stream pid);
                    kill pid Sys.sigterm;
                    Unix.sleepf 0.02;
                    kill pid Sys.sigkill;
                    ignore (waitpid_nointr [] pid);
                    drain (Output_exceeded stream) open_fds
                | None -> (
                    if cancelled () then begin
                      kill pid Sys.sigterm;
                      Unix.sleepf 0.02;
                      kill pid Sys.sigkill;
                      ignore (waitpid_nointr [] pid);
                      drain Cancelled open_fds
                    end
                    else
                      let open_fds = poll open_fds in
                      match waitpid_nointr [ Unix.WNOHANG ] pid with
                      | 0, _ -> wait open_fds
                      | _, status -> drain (status_of_unix status) open_fds)
              in
              let status = wait [ stdout_r; stderr_r ] in
              cleanup ();
              let status =
                match !read_failure with
                | None -> status
                | Some message -> Failed message
              in
              {
                status;
                stdout = Buffer.contents stdout;
                stderr = Buffer.contents stderr;
              }))

(* The capture loops above block on [Unix.select]/[Unix.sleepf] and never
   yield; on the calling fiber they starve the whole Eio domain — a frozen
   TUI (no frames, no input, no resize handling) for the lifetime of the
   child. Hop to a systhread so the calling fiber suspends instead.
   [cancelled] is polled from that systhread; it must be a plain flag read. *)

let run_shell ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin ~cancelled argv =
  Eio_unix.run_in_systhread ~label:"spice-shell" (fun () ->
      run_shell_blocking ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin
        ~cancelled argv)

let run_sandboxed_shell ~sandbox ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin
    ~cancelled argv =
  match prepare ~sandbox ~env argv with
  | Error error ->
      {
        shell_status = Shell_refused error;
        shell_stdout = Complete "";
        shell_stderr = Complete "";
        shell_duration_ms = 0;
      }
  | Ok (argv, env) ->
      run_shell ~cwd ~env ~timeout_ms ~max_output_bytes ?stdin ~cancelled argv

let run ?stdout_limit ?stderr_limit ~cancelled argv =
  Eio_unix.run_in_systhread ~label:"spice-process" (fun () ->
      run_blocking ?stdout_limit ?stderr_limit ~env:(Unix.environment ())
        ~cancelled argv)

let run_sandboxed ?stdout_limit ?stderr_limit ~sandbox ~cancelled argv =
  match prepare ~sandbox ~env:(Unix.environment ()) argv with
  | Error error -> { status = Refused error; stdout = ""; stderr = "" }
  | Ok (argv, env) ->
      Eio_unix.run_in_systhread ~label:"spice-process" (fun () ->
          run_blocking ?stdout_limit ?stderr_limit ~env ~cancelled argv)
