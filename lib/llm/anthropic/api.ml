(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let log_src = Logs.Src.create "spice.llm.anthropic" ~doc:"Anthropic provider"

module Log = (val Logs.src_log log_src : Logs.LOG)

let api = "messages"
let default_base_url = "https://api.anthropic.com/v1"
let default_max_retries = 2
let max_error_body_size = 65_536

module Error = struct
  type response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  type t = Response of response | Transport of string | Decode of string
end

module Client = struct
  type auth = Api_key of string | Bearer of string

  type t = {
    config : Config.t;
    auth : auth;
    sw : Eio.Switch.t;
    env : Eio_unix.Stdenv.base;
  }

  let make config ~sw ~env ~auth () = { config; auth; sw; env }
  let config t = t.config
  let sw t = t.sw
  let env t = t.env

  let auth_header t =
    match t.auth with
    | Api_key key -> ("x-api-key", key)
    | Bearer token -> ("authorization", "Bearer " ^ token)
end

let retryable_status status =
  status = 408 || status = 409 || status = 429 || status >= 500

let cohttp_method = function
  | "POST" -> `POST
  | method_ -> invalid_arg ("unsupported HTTP method: " ^ method_)

let https ~authenticator =
  let tls_config =
    match Tls.Config.client ~authenticator () with
    | Error (`Msg message) -> failwith ("TLS configuration error: " ^ message)
    | Ok config -> config
  in
  fun uri raw ->
    let host =
      Uri.host uri
      |> Option.map (fun value -> Domain_name.(host_exn (of_string_exn value)))
    in
    Tls_eio.client_of_flow ?host tls_config raw

let cohttp_headers headers =
  List.fold_left
    (fun acc (name, value) -> Cohttp.Header.add acc name value)
    (Cohttp.Header.init ()) headers

let read_body body =
  let chunk = Cstruct.create 4096 in
  let buffer = Buffer.create 1024 in
  let rec loop remaining =
    if remaining > 0 then
      match Eio.Flow.single_read body chunk with
      | exception End_of_file -> ()
      | count ->
          let count = min count remaining in
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop (remaining - count)
  in
  loop max_error_body_size;
  Buffer.contents buffer

let headers t attempt =
  [
    Client.auth_header t;
    ("content-type", "application/json");
    ("accept", "text/event-stream");
    ("anthropic-version", "2023-06-01");
    ("user-agent", "spice-llm-anthropic/0");
    ("x-stainless-retry-count", string_of_int attempt);
  ]

type http_request = {
  meth : string;
  url : string;
  headers : (string * string) list;
  body : string;
  timeout_s : float option;
}

let make_request t ~path ~body attempt =
  let config = Client.config t in
  let base_url =
    Option.value (Config.base_url config) ~default:default_base_url
  in
  {
    meth = "POST";
    url = base_url ^ path;
    headers = headers t attempt;
    body;
    timeout_s = Config.timeout_s config;
  }

let call_cohttp_stream ~sw client request =
  let response, body =
    Cohttp_eio.Client.call client ~sw
      ~headers:(cohttp_headers request.headers)
      ~body:(Cohttp_eio.Body.of_string request.body)
      (cohttp_method request.meth)
      (Uri.of_string request.url)
  in
  let response_head =
    {
      Error.status =
        Cohttp.Code.code_of_status (Cohttp.Response.status response);
      headers = Cohttp.Header.to_list (Cohttp.Response.headers response);
      body = "";
    }
  in
  if response_head.Error.status < 200 || response_head.Error.status >= 300 then
    Error (Error.Response { response_head with Error.body = read_body body })
  else Ok body

let cohttp_stream t request =
  try
    Mirage_crypto_rng_unix.use_default ();
    let authenticator =
      match Ca_certs.authenticator () with
      | Ok authenticator -> authenticator
      | Error (`Msg message) -> failwith ("X509 authenticator: " ^ message)
    in
    let env = Client.env t in
    let sw = Client.sw t in
    let http_client =
      Cohttp_eio.Client.make ~https:(Some (https ~authenticator)) env#net
    in
    match request.timeout_s with
    | None -> call_cohttp_stream ~sw http_client request
    | Some seconds ->
        Eio.Time.with_timeout_exn env#clock seconds (fun () ->
            call_cohttp_stream ~sw http_client request)
  with
  | Eio.Time.Timeout ->
      Error (Error.Transport "Anthropic HTTP transport timed out")
  | exn -> Error (Error.Transport (Printexc.to_string exn))

let stream_post t ~path ~body =
  let max_retries =
    Option.value
      (Config.max_retries (Client.config t))
      ~default:default_max_retries
  in
  let clock = (Client.env t)#clock in
  let rec loop attempt delay =
    let request = make_request t ~path ~body attempt in
    match cohttp_stream t request with
    | Error (Error.Response response)
      when retryable_status response.Error.status
           && attempt
              < Spice_llm.Retry.budget ~max_retries
                  ~status:response.Error.status ->
        (* Server-provided delays are honored but bounded: an absurd
           Retry-After must not park a turn for hours. *)
        let sleep =
          Float.min Spice_llm.Retry.max_honored_delay
            (Float.max delay
               (Option.value
                  (Spice_llm.Retry.after ~now:(Eio.Time.now clock)
                     response.Error.headers)
                  ~default:0.))
        in
        Log.warn (fun m ->
            m "retrying after status=%d attempt=%d delay=%.1fs"
              response.Error.status attempt sleep);
        Eio.Time.sleep clock sleep;
        loop (attempt + 1) (delay *. 1.5)
    | Error (Error.Transport _) when attempt < max_retries ->
        Log.warn (fun m ->
            m "retrying after transport error attempt=%d delay=%.1fs" attempt
              delay);
        Eio.Time.sleep clock delay;
        loop (attempt + 1) (delay *. 1.5)
    | Error error -> Error error
    | Ok body -> Ok body
  in
  loop 0 0.5

let json_member name value = Jsont.Json.mem (Jsont.Json.name name) value
let string_member name value = json_member name (Jsont.Json.string value)
let bool_member name value = json_member name (Jsont.Json.bool value)
let int_member name value = json_member name (Jsont.Json.int value)
let number_member name value = json_member name (Jsont.Json.number value)
let list_member name value = json_member name (Jsont.Json.list value)

let add_opt member name value fields =
  match value with None -> fields | Some value -> member name value :: fields

let json_string json =
  match Jsont_bytesrw.encode_string Jsont.json json with
  | Ok value -> Ok value
  | Error message -> Error (Error.Decode ("JSON encode failed: " ^ message))

type line_reader = {
  flow : Eio.Flow.source_ty Eio.Std.r;
  chunk : Cstruct.t;
  mutable head : int;
  mutable tail : int;
  mutable closed : bool;
}

let make_line_reader flow =
  {
    flow :> Eio.Flow.source_ty Eio.Std.r;
    chunk = Cstruct.create 4096;
    head = 0;
    tail = 0;
    closed = false;
  }

let refill_line_reader reader =
  reader.head <- 0;
  reader.tail <- 0;
  match Eio.Flow.single_read reader.flow reader.chunk with
  | exception End_of_file -> reader.closed <- true
  | count -> reader.tail <- count

let read_line reader =
  let buffer = Buffer.create 256 in
  let rec loop () =
    if reader.head >= reader.tail then
      if reader.closed then
        if Buffer.length buffer = 0 then raise End_of_file
        else Buffer.contents buffer
      else (
        refill_line_reader reader;
        if reader.closed && reader.tail = 0 then
          if Buffer.length buffer = 0 then raise End_of_file
          else Buffer.contents buffer
        else loop ())
    else
      let char = Cstruct.get_char reader.chunk reader.head in
      reader.head <- reader.head + 1;
      match char with
      | '\n' -> Buffer.contents buffer
      | '\r' -> loop ()
      | char ->
          Buffer.add_char buffer char;
          loop ()
  in
  loop ()

module Messages = struct
  type request = {
    model : string;
    system : Jsont.json list;
    messages : Jsont.json list;
    tools : Jsont.json list;
    tool_choice : Jsont.json option;
    thinking : Jsont.json option;
    max_tokens : int;
    temperature : float option;
    stream : bool;
  }

  type event = { name : string; data : Jsont.json }

  type stream = {
    next : unit -> (event, Error.t) result option;
    close : unit -> unit;
  }

  let next stream = stream.next ()
  let close stream = stream.close ()

  let body request =
    let fields =
      [
        string_member "model" request.model;
        list_member "messages" request.messages;
        int_member "max_tokens" request.max_tokens;
        bool_member "stream" request.stream;
      ]
    in
    let fields =
      match request.system with
      | [] -> fields
      | system -> list_member "system" system :: fields
    in
    let fields =
      match request.tools with
      | [] -> fields
      | tools -> list_member "tools" tools :: fields
    in
    let fields = add_opt json_member "tool_choice" request.tool_choice fields in
    let fields = add_opt json_member "thinking" request.thinking fields in
    let fields =
      add_opt number_member "temperature" request.temperature fields
    in
    Jsont.Json.object' (List.rev fields)

  let event_type = function
    | Jsont.Object (fields, _) -> (
        match Jsont.Json.find_mem "type" fields with
        | Some (_, Jsont.String (value, _)) -> Some value
        | Some _ | None -> None)
    | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
    | Jsont.Array _ ->
        None

  let decode_sse_event name raw_data =
    match Jsont_bytesrw.decode_string Jsont.json raw_data with
    | Error message ->
        Error (Error.Decode ("Anthropic stream JSON decode failed: " ^ message))
    | Ok data -> (
        match (name, event_type data) with
        | "", None -> Error (Error.Decode "Anthropic stream event missing type")
        | "", Some name | name, _ -> Ok { name; data })

  let next_sse_event read_line =
    let event_name = Buffer.create 16 in
    let data = Buffer.create 1024 in
    let finish () =
      let name = Buffer.contents event_name in
      if Buffer.length data = 0 then None
      else Some (decode_sse_event name (Buffer.contents data))
    in
    let rec loop () =
      match read_line () with
      | exception End_of_file -> finish ()
      | line ->
          if String.is_empty line then
            match finish () with None -> loop () | Some _ as event -> event
          else (
            (match String.split_first ~sep:":" line with
            | None -> ()
            | Some (key, value) ->
                let value =
                  if String.starts_with ~prefix:" " value then
                    String.drop_first 1 value
                  else value
                in
                if String.equal key "event" then
                  Buffer.add_string event_name value
                else if String.equal key "data" then (
                  if Buffer.length data > 0 then Buffer.add_char data '\n';
                  Buffer.add_string data value));
            loop ())
    in
    loop ()

  let stream_of_flow body =
    let reader = make_line_reader body in
    let closed = ref false in
    {
      next =
        (fun () ->
          if !closed then None else next_sse_event (fun () -> read_line reader));
      close = (fun () -> closed := true);
    }

  let create_stream client request =
    match json_string (body request) with
    | Error error -> Error error
    | Ok body ->
        Result.map stream_of_flow (stream_post client ~path:"/messages" ~body)
end
