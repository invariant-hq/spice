module Process = Process_under_test

let fail message = raise (Failure message)

let read_pid path =
  In_channel.with_open_text path (fun input ->
      input |> In_channel.input_all |> String.trim |> int_of_string)

let exists signal_target =
  match Unix.kill signal_target 0 with
  | () -> true
  | exception Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | exception Unix.Unix_error _ -> true

let await_file clock path =
  Eio.Time.with_timeout_exn clock 1. (fun () ->
      while not (Sys.file_exists path) do
        Eio.Time.sleep clock 0.005
      done)

let await_gone clock signal_target =
  Eio.Time.with_timeout_exn clock 1. (fun () ->
      while exists signal_target do
        Eio.Time.sleep clock 0.005
      done)

let blocking_process pid_path =
  [
    "/bin/sh";
    "-c";
    "echo $$ > " ^ Filename.quote pid_path
    ^ "; trap '' TERM; exec sleep 600";
  ]

let assert_process_reaped clock pid_path =
  let pid = read_pid pid_path in
  await_gone clock pid

let assert_bounded started label =
  if Unix.gettimeofday () -. started > 1. then
    fail (label ^ " exceeded its teardown bound")

let () =
  Eio_main.run @@ fun stdenv ->
  let clock = Eio.Stdenv.clock stdenv in
  let root = Filename.temp_dir "spice-process-test" "" in
  let timeout_pid = Filename.concat root "timeout.pid" in
  let cancelled_pid = Filename.concat root "cancelled.pid" in
  let output_pid = Filename.concat root "output.pid" in
  let remove path = try Unix.unlink path with Unix.Unix_error _ -> () in
  Fun.protect
    ~finally:(fun () ->
      List.iter remove [ timeout_pid; cancelled_pid; output_pid ];
      try Unix.rmdir root with Unix.Unix_error _ -> ())
    (fun () ->
      let success =
        Process.run ~timeout_ms:1_000 ~cancelled:(fun () -> false)
          [ "/usr/bin/true" ]
      in
      (match success.Process.status with
      | Process.Exited 0 -> ()
      | _ -> fail "direct process did not report a successful exit");
      let started = Unix.gettimeofday () in
      let timed =
        Process.run ~timeout_ms:50 ~cancelled:(fun () -> false)
          (blocking_process timeout_pid)
      in
      (match timed.Process.status with
      | Process.Timed_out { timeout_ms = 50 } -> ()
      | _ -> fail "direct process did not report its timeout");
      assert_bounded started "direct process timeout";
      assert_process_reaped clock timeout_pid;
      let cancelled = ref false in
      Eio.Switch.run @@ fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
          await_file clock cancelled_pid;
          cancelled := true);
      let started = Unix.gettimeofday () in
      let cancelled_result =
        Process.run ~timeout_ms:5_000 ~cancelled:(fun () -> !cancelled)
          (blocking_process cancelled_pid)
      in
      (match cancelled_result.Process.status with
      | Process.Cancelled -> ()
      | _ -> fail "direct process did not report cancellation");
      assert_bounded started "direct process cancellation";
      assert_process_reaped clock cancelled_pid;
      let output =
        Process.run ~stdout_limit:32 ~timeout_ms:5_000
          ~cancelled:(fun () -> false)
          [
            "/bin/sh";
            "-c";
            "echo $$ > " ^ Filename.quote output_pid
            ^ "; trap '' TERM; while :; do printf 0123456789; done";
          ]
      in
      (match output.Process.status with
      | Process.Output_exceeded "stdout" -> ()
      | _ -> fail "direct process did not enforce its output bound");
      assert_process_reaped clock output_pid)
