(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let failf fmt = Printf.ksprintf failwith fmt

let resolve_env_path name =
  match Sys.getenv_opt name with
  | Some path ->
      let path =
        if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
        else path
      in
      if Sys.file_exists path then path
      else failf "%s does not exist: %s" name path
  | None -> failf "%s is not set" name

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

let write_file path text =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc text)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter
        (fun name ->
          if not (String.equal name "." || String.equal name "..") then
            rm_rf (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path

let wait_for_file path =
  let rec loop remaining =
    if remaining <= 0 then failf "timed out waiting for %s" path
    else if
      Sys.file_exists path
      &&
      let stat = Unix.stat path in
      stat.Unix.st_size > 0
    then ()
    else (
      Unix.sleepf 0.05;
      loop (remaining - 1))
  in
  loop 200

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    index + needle_len <= haystack_len
    && (String.equal (String.sub haystack index needle_len) needle
       || loop (index + 1))
  in
  needle_len = 0 || loop 0

let rstrip s =
  let i = ref (String.length s - 1) in
  while !i >= 0 && s.[!i] = ' ' do
    decr i
  done;
  String.sub s 0 (!i + 1)

let replace_all ~pattern ~with_ text =
  let pattern_len = String.length pattern in
  if pattern_len = 0 then text
  else
    let text_len = String.length text in
    let out = Buffer.create text_len in
    let rec loop index =
      if index >= text_len then ()
      else if
        index + pattern_len <= text_len
        && String.equal (String.sub text index pattern_len) pattern
      then (
        Buffer.add_string out with_;
        loop (index + pattern_len))
      else (
        Buffer.add_char out text.[index];
        loop (index + 1))
    in
    loop 0;
    Buffer.contents out

let print_fact label value = Printf.printf "%s: %b\n" label value
