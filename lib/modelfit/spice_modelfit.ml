(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let mib = 1024 * 1024
let gib = 1024 * mib

let pp_bytes ppf bytes =
  if bytes >= gib then Format.fprintf ppf "%.1f GiB" (float bytes /. float gib)
  else Format.fprintf ppf "%.0f MiB" (float bytes /. float mib)

module Machine = struct
  type os = Macos | Linux | Other
  type t = { os : os; ram_bytes : int; wired_limit_bytes : int option }

  let make ~os ~ram_bytes ?wired_limit_bytes () =
    if ram_bytes <= 0 then
      invalid_arg "Spice_modelfit.Machine.make: ram_bytes must be positive";
    (match wired_limit_bytes with
    | Some limit when limit <= 0 ->
        invalid_arg
          "Spice_modelfit.Machine.make: wired_limit_bytes must be positive"
    | Some _ | None -> ());
    { os; ram_bytes; wired_limit_bytes }

  external sysctl_u64 : string -> int64 = "spice_modelfit_sysctl_u64"

  let proc_meminfo_ram () =
    match In_channel.with_open_text "/proc/meminfo" In_channel.input_all with
    | exception Sys_error _ -> None
    | contents ->
        String.split_on_char '\n' contents
        |> List.find_map (fun line ->
            match String.split_on_char ':' line with
            | [ "MemTotal"; rest ] -> (
                match String.trim rest |> String.split_on_char ' ' with
                | kib :: _ -> (
                    match int_of_string_opt kib with
                    | Some kib when kib > 0 -> Some (kib * 1024)
                    | Some _ | None -> None)
                | [] -> None)
            | _ -> None)

  let detect () =
    match proc_meminfo_ram () with
    | Some ram_bytes -> Some (make ~os:Linux ~ram_bytes ())
    | None ->
        let memsize = sysctl_u64 "hw.memsize" in
        if Int64.compare memsize 0L <= 0 then None
        else
          let wired_mb = sysctl_u64 "iogpu.wired_limit_mb" in
          let wired_limit_bytes =
            if Int64.compare wired_mb 0L > 0 then
              Some (Int64.to_int wired_mb * mib)
            else None
          in
          Some
            (make ~os:Macos ~ram_bytes:(Int64.to_int memsize) ?wired_limit_bytes
               ())

  let os t = t.os
  let ram_bytes t = t.ram_bytes

  let budget t =
    match t with
    | { os = Macos; wired_limit_bytes = Some limit; _ } -> limit
    | { ram_bytes; _ } -> ram_bytes / 4 * 3

  let pp ppf t =
    let os =
      match t.os with Macos -> "macos" | Linux -> "linux" | Other -> "other"
    in
    Format.fprintf ppf "%s, %a RAM, %a budget" os pp_bytes t.ram_bytes pp_bytes
      (budget t)
end

module Model = struct
  type t = {
    weights_bytes : int;
    n_kv_layers : int;
    n_kv_heads : int;
    head_dim : int;
    max_context : int;
  }

  let make ~weights_bytes ~n_kv_layers ~n_kv_heads ~head_dim ~max_context =
    let field name value =
      if value <= 0 then
        invalid_arg
          (Printf.sprintf "Spice_modelfit.Model.make: %s must be positive" name)
    in
    field "weights_bytes" weights_bytes;
    field "n_kv_layers" n_kv_layers;
    field "n_kv_heads" n_kv_heads;
    field "head_dim" head_dim;
    field "max_context" max_context;
    { weights_bytes; n_kv_layers; n_kv_heads; head_dim; max_context }

  let weights_bytes t = t.weights_bytes
  let n_kv_layers t = t.n_kv_layers
  let n_kv_heads t = t.n_kv_heads
  let head_dim t = t.head_dim
  let max_context t = t.max_context

  let pp ppf t =
    Format.fprintf ppf
      "%a weights, %d kv layers, %d kv heads, head dim %d, max context %d"
      pp_bytes t.weights_bytes t.n_kv_layers t.n_kv_heads t.head_dim
      t.max_context
end

type kv_dtype = F16 | Q8_0 | Q4_0

(* Bytes per cached element. The quantized types store 32-element blocks with
   a 2-byte scale: 34 and 18 bytes per block. *)
let kv_bytes_per_element = function
  | F16 -> 2.0
  | Q8_0 -> 34.0 /. 32.0
  | Q4_0 -> 18.0 /. 32.0

let kv_bytes_per_token kv_dtype model =
  2.0
  *. float (Model.n_kv_layers model)
  *. float (Model.n_kv_heads model)
  *. float (Model.head_dim model)
  *. kv_bytes_per_element kv_dtype

(* Compute graph and engine allowance (~1 GiB, matching Ollama's reserve)
   plus a safety margin against estimate error (~640 MiB). *)
let overhead_bytes = gib + (640 * mib)

module Estimate = struct
  type t = { weights_bytes : int; kv_cache_bytes : int; overhead_bytes : int }

  let total_bytes t = t.weights_bytes + t.kv_cache_bytes + t.overhead_bytes

  let pp ppf t =
    Format.fprintf ppf "%a weights + %a kv cache + %a overhead = %a" pp_bytes
      t.weights_bytes pp_bytes t.kv_cache_bytes pp_bytes t.overhead_bytes
      pp_bytes (total_bytes t)
end

let estimate ?(kv_dtype = F16) ~context model =
  if context <= 0 then
    invalid_arg "Spice_modelfit.estimate: context must be positive";
  let context = Int.min context (Model.max_context model) in
  let kv_cache_bytes =
    Float.to_int
      (Float.ceil (kv_bytes_per_token kv_dtype model *. float context))
  in
  {
    Estimate.weights_bytes = Model.weights_bytes model;
    kv_cache_bytes;
    overhead_bytes;
  }

let default_context = 32768
let min_useful_context = 8192

module Verdict = struct
  type t = Fits | Tight of { max_context : int } | Wont_run

  let equal a b =
    match (a, b) with
    | Fits, Fits | Wont_run, Wont_run -> true
    | Tight { max_context = a }, Tight { max_context = b } -> Int.equal a b
    | (Fits | Tight _ | Wont_run), _ -> false

  let pp ppf = function
    | Fits -> Format.pp_print_string ppf "fits"
    | Tight { max_context } ->
        Format.fprintf ppf "fits up to a %d-token context" max_context
    | Wont_run -> Format.pp_print_string ppf "won't run"
end

let max_context ?(kv_dtype = F16) ~budget model =
  if budget <= 0 then None
  else
    let available = budget - Model.weights_bytes model - overhead_bytes in
    if available <= 0 then None
    else
      let tokens =
        Float.to_int (float available /. kv_bytes_per_token kv_dtype model)
      in
      if tokens < 1 then None
      else Some (Int.min tokens (Model.max_context model))

let verdict ?(kv_dtype = F16) ?(context = default_context) ~budget model =
  if context <= 0 then
    invalid_arg "Spice_modelfit.verdict: context must be positive";
  let requested = Int.min context (Model.max_context model) in
  match max_context ~kv_dtype ~budget model with
  | None -> Verdict.Wont_run
  | Some fitting when fitting >= requested -> Verdict.Fits
  | Some fitting when fitting < min_useful_context -> Verdict.Wont_run
  | Some fitting -> Verdict.Tight { max_context = fitting }

module Gguf = struct
  type t = {
    architecture : string;
    name : string option;
    n_layers : int option;
    context_length : int option;
    embedding_length : int option;
    head_count : int option;
    head_count_kv : int option;
    key_length : int option;
    value_length : int option;
  }

  module Error = struct
    type t = Truncated | Malformed of string

    let pp ppf = function
      | Truncated -> Format.pp_print_string ppf "truncated GGUF header"
      | Malformed reason ->
          Format.fprintf ppf "malformed GGUF header: %s" reason
  end

  module Model_error = struct
    type t =
      | Missing_metadata of { key : string }
      | Missing_any_metadata of { keys : string list }
      | Invalid_metadata of { key : string }
      | Invalid_head_dimensions of { architecture : string }

    let pp_keys ppf = function
      | [] -> ()
      | [ key ] -> Format.pp_print_string ppf key
      | keys ->
          Format.pp_print_list
            ~pp_sep:(fun ppf () -> Format.pp_print_string ppf " or ")
            Format.pp_print_string ppf keys

    let pp ppf = function
      | Missing_metadata { key } -> Format.fprintf ppf "missing %s" key
      | Missing_any_metadata { keys } ->
          Format.fprintf ppf "missing %a" pp_keys keys
      | Invalid_metadata { key } -> Format.fprintf ppf "invalid %s" key
      | Invalid_head_dimensions { architecture } ->
          Format.fprintf ppf "invalid %s head dimensions" architecture
  end

  exception Truncated_exn
  exception Malformed_exn of string

  let malformed fmt = Printf.ksprintf (fun m -> raise (Malformed_exn m)) fmt

  type cursor = { data : string; mutable pos : int }

  let need cursor count =
    if count < 0 || count > String.length cursor.data - cursor.pos then
      raise Truncated_exn

  let u8 cursor =
    need cursor 1;
    let value = Char.code cursor.data.[cursor.pos] in
    cursor.pos <- cursor.pos + 1;
    value

  let u32 cursor =
    need cursor 4;
    let value = String.get_int32_le cursor.data cursor.pos in
    cursor.pos <- cursor.pos + 4;
    Int32.to_int value land 0xFFFFFFFF

  let u64 cursor =
    need cursor 8;
    let value = String.get_int64_le cursor.data cursor.pos in
    cursor.pos <- cursor.pos + 8;
    if
      Int64.compare value 0L < 0
      || Int64.compare value (Int64.of_int max_int) > 0
    then malformed "64-bit value out of range";
    Int64.to_int value

  let signed cursor bytes =
    need cursor bytes;
    let value =
      match bytes with
      | 1 ->
          let v = Char.code cursor.data.[cursor.pos] in
          if v > 0x7F then v - 0x100 else v
      | 2 ->
          let v = String.get_int16_le cursor.data cursor.pos in
          v
      | 4 -> Int32.to_int (String.get_int32_le cursor.data cursor.pos)
      | _ -> Int64.to_int (String.get_int64_le cursor.data cursor.pos)
    in
    cursor.pos <- cursor.pos + bytes;
    value

  let string_field cursor =
    let length = u64 cursor in
    need cursor length;
    let value = String.sub cursor.data cursor.pos length in
    cursor.pos <- cursor.pos + length;
    value

  let skip cursor count =
    need cursor count;
    cursor.pos <- cursor.pos + count

  (* GGUF metadata value types, by wire tag. *)
  type vtype =
    | T_u8
    | T_i8
    | T_u16
    | T_i16
    | T_u32
    | T_i32
    | T_f32
    | T_bool
    | T_string
    | T_array
    | T_u64
    | T_i64
    | T_f64

  let vtype cursor =
    match u32 cursor with
    | 0 -> T_u8
    | 1 -> T_i8
    | 2 -> T_u16
    | 3 -> T_i16
    | 4 -> T_u32
    | 5 -> T_i32
    | 6 -> T_f32
    | 7 -> T_bool
    | 8 -> T_string
    | 9 -> T_array
    | 10 -> T_u64
    | 11 -> T_i64
    | 12 -> T_f64
    | tag -> malformed "unknown metadata value type %d" tag

  let fixed_size = function
    | T_u8 | T_i8 | T_bool -> Some 1
    | T_u16 | T_i16 -> Some 2
    | T_u32 | T_i32 | T_f32 -> Some 4
    | T_u64 | T_i64 | T_f64 -> Some 8
    | T_string | T_array -> None

  let rec skip_value cursor ty =
    match fixed_size ty with
    | Some size -> skip cursor size
    | None -> (
        match ty with
        | T_string -> skip cursor (u64 cursor)
        | _ -> (
            let element = vtype cursor in
            let count = u64 cursor in
            match fixed_size element with
            | Some size ->
                if count > 0 && size > max_int / count then
                  malformed "array too large";
                skip cursor (count * size)
            | None ->
                for _ = 1 to count do
                  skip_value cursor element
                done))

  let uint_scalar cursor = function
    | T_u8 -> u8 cursor
    | T_u16 ->
        need cursor 2;
        let v = String.get_uint16_le cursor.data cursor.pos in
        cursor.pos <- cursor.pos + 2;
        v
    | T_u32 -> u32 cursor
    | T_u64 -> u64 cursor
    | (T_i8 | T_i16 | T_i32 | T_i64) as ty ->
        let bytes =
          match ty with T_i8 -> 1 | T_i16 -> 2 | T_i32 -> 4 | _ -> 8
        in
        let value = signed cursor bytes in
        if value < 0 then malformed "negative integer metadata value";
        value
    | T_f32 | T_f64 | T_bool | T_string | T_array ->
        malformed "expected integer metadata value"

  (* Integer-valued key. Per-layer arrays (some models record head_count_kv
     per layer) reduce to their maximum, which overestimates and errs toward
     caution. *)
  let uint_value cursor ty =
    match ty with
    | T_array ->
        let element = vtype cursor in
        let count = u64 cursor in
        if count = 0 then malformed "empty integer array metadata value";
        let best = ref 0 in
        for _ = 1 to count do
          best := Int.max !best (uint_scalar cursor element)
        done;
        !best
    | _ -> uint_scalar cursor ty

  let string_value cursor = function
    | T_string -> string_field cursor
    | _ -> malformed "expected string metadata value"

  type state = {
    mutable arch : string option;
    mutable model_name : string option;
    mutable layers : int option;
    mutable ctx : int option;
    mutable embd : int option;
    mutable heads : int option;
    mutable kv_heads : int option;
    mutable k_len : int option;
    mutable v_len : int option;
  }

  (* The keys [model] can derive guard inputs from. *)
  let minimum_complete s =
    s.arch <> None && s.layers <> None && s.ctx <> None
    && (s.k_len <> None || (s.embd <> None && s.heads <> None))
    && (s.kv_heads <> None || s.heads <> None)

  (* Every fit-relevant key seen; nothing further to look for. *)
  let all_seen s =
    s.arch <> None && s.layers <> None && s.ctx <> None && s.embd <> None
    && s.heads <> None && s.kv_heads <> None && s.k_len <> None
    && s.v_len <> None

  let of_prefix data =
    let cursor = { data; pos = 0 } in
    try
      need cursor 4;
      if String.sub data 0 4 <> "GGUF" then malformed "bad magic";
      cursor.pos <- 4;
      let version = u32 cursor in
      if version <> 2 && version <> 3 then
        malformed "unsupported GGUF version %d" version;
      let _tensor_count = u64 cursor in
      let kv_count = u64 cursor in
      let s =
        {
          arch = None;
          model_name = None;
          layers = None;
          ctx = None;
          embd = None;
          heads = None;
          kv_heads = None;
          k_len = None;
          v_len = None;
        }
      in
      (try
         for _ = 1 to kv_count do
           if all_seen s then raise Exit;
           let key = string_field cursor in
           (* Tokenizer entries are megabytes of vocabulary and follow the
              architecture block; stop before them once derivable. *)
           if String.starts_with ~prefix:"tokenizer." key && minimum_complete s
           then raise Exit;
           let ty = vtype cursor in
           let arch_key suffix =
             match s.arch with
             | Some arch ->
                 String.length key = String.length arch + String.length suffix
                 && String.starts_with ~prefix:arch key
                 && String.ends_with ~suffix key
             | None -> false
           in
           if String.equal key "general.architecture" then
             s.arch <- Some (string_value cursor ty)
           else if String.equal key "general.name" then
             s.model_name <- Some (string_value cursor ty)
           else if arch_key ".block_count" then
             s.layers <- Some (uint_value cursor ty)
           else if arch_key ".context_length" then
             s.ctx <- Some (uint_value cursor ty)
           else if arch_key ".embedding_length" then
             s.embd <- Some (uint_value cursor ty)
           else if arch_key ".attention.head_count" then
             s.heads <- Some (uint_value cursor ty)
           else if arch_key ".attention.head_count_kv" then
             s.kv_heads <- Some (uint_value cursor ty)
           else if arch_key ".attention.key_length" then
             s.k_len <- Some (uint_value cursor ty)
           else if arch_key ".attention.value_length" then
             s.v_len <- Some (uint_value cursor ty)
           else skip_value cursor ty
         done
       with Exit -> ());
      match s.arch with
      | None -> Error (Error.Malformed "missing general.architecture")
      | Some architecture ->
          Ok
            {
              architecture;
              name = s.model_name;
              n_layers = s.layers;
              context_length = s.ctx;
              embedding_length = s.embd;
              head_count = s.heads;
              head_count_kv = s.kv_heads;
              key_length = s.k_len;
              value_length = s.v_len;
            }
    with
    | Truncated_exn -> Error Error.Truncated
    | Malformed_exn reason -> Error (Error.Malformed reason)

  let architecture t = t.architecture
  let name t = t.name

  let model ~weights_bytes t =
    if weights_bytes <= 0 then
      invalid_arg "Spice_modelfit.Gguf.model: weights_bytes must be positive";
    let key suffix = t.architecture ^ "." ^ suffix in
    let missing suffix =
      Error (Model_error.Missing_metadata { key = key suffix })
    in
    let missing_any suffixes =
      Error (Model_error.Missing_any_metadata { keys = List.map key suffixes })
    in
    let invalid suffix =
      Error (Model_error.Invalid_metadata { key = key suffix })
    in
    let positive suffix = function
      | Some value when value > 0 -> Ok value
      | Some _ -> invalid suffix
      | None -> missing suffix
    in
    let invalid_head_dimensions () =
      Error
        (Model_error.Invalid_head_dimensions { architecture = t.architecture })
    in
    let mean_rounded_up a b =
      if a > max_int - b then invalid_head_dimensions ()
      else
        let sum = a + b in
        Ok ((sum / 2) + (sum mod 2))
    in
    let open Result.Syntax in
    let* n_kv_layers = positive "block_count" t.n_layers in
    let* max_context = positive "context_length" t.context_length in
    let* n_kv_heads =
      match t.head_count_kv with
      | Some _ -> positive "attention.head_count_kv" t.head_count_kv
      | None -> positive "attention.head_count" t.head_count
    in
    let* head_dim =
      (* The estimate multiplies by [2 * head_dim] for K plus V. When the mean
         is fractional, round up so malformed metadata cannot undercount KV. *)
      match (t.key_length, t.value_length) with
      | Some k, Some v when k > 0 && v > 0 -> mean_rounded_up k v
      | Some k, None when k > 0 -> Ok k
      | Some _, _ -> invalid "attention.key_length"
      | None, _ -> (
          match (t.embedding_length, t.head_count) with
          | Some embd, Some heads
            when embd > 0 && heads > 0 && embd mod heads = 0 ->
              Ok (embd / heads)
          | Some _, Some _ -> invalid_head_dimensions ()
          | None, _ ->
              missing_any [ "attention.key_length"; "embedding_length" ]
          | _, None -> missing "attention.head_count")
    in
    if head_dim <= 0 then invalid_head_dimensions ()
    else
      Ok
        (Model.make ~weights_bytes ~n_kv_layers ~n_kv_heads ~head_dim
           ~max_context)
end
