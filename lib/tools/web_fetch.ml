(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let log_src = Logs.Src.create "spice.tools.web_fetch" ~doc:"Web fetch tool"

module Log = (val Logs.src_log log_src : Logs.LOG)

let name = "web_fetch"
let description = Spice_prompts.Tools.web_fetch

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

module Input = struct
  type format = Markdown | Text | Html
  type t = { url : string; format : format; timeout_ms : int option }

  let format_to_string = function
    | Markdown -> "markdown"
    | Text -> "text"
    | Html -> "html"

  let format_of_string = function
    | "markdown" -> Markdown
    | "text" -> Text
    | "html" -> Html
    | format -> invalid_arg ("unknown format: " ^ format)

  let make ?(format = Markdown) ?timeout_ms url =
    if String.is_empty url then invalid_arg "url must not be empty";
    if String.contains url '\000' then invalid_arg "url must not contain NUL";
    begin match timeout_ms with
    | Some timeout_ms when timeout_ms <= 0 ->
        invalid_arg "timeout_ms must be positive"
    | Some _ | None -> ()
    end;
    { url; format; timeout_ms }

  let make_json url format timeout_ms =
    decode_invalid_arg (fun () ->
        let format = Option.map format_of_string format in
        make ?format ?timeout_ms url)

  let url t = t.url
  let format t = t.format
  let timeout_ms t = t.timeout_ms

  let codec =
    Jsont.Object.map ~kind:"web_fetch input" make_json
    |> Jsont.Object.mem "url" Jsont.string ~enc:url
    |> Jsont.Object.opt_mem "format" Jsont.string ~enc:(fun t ->
        Some (format_to_string (format t)))
    |> Jsont.Object.opt_mem "timeout_ms" Jsont.int ~enc:timeout_ms
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "url",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string "Public HTTP or HTTPS URL to fetch." );
                  ] );
              ( "format",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "markdown";
                          Json.string "text";
                          Json.string "html";
                        ] );
                    ( "description",
                      Json.string
                        "Returned content format. Defaults to markdown." );
                  ] );
              ( "timeout_ms",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ( "description",
                      Json.string
                        "Request timeout in milliseconds, capped by host \
                         policy." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "url" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

let protocol_of_url url =
  match Web.Url.scheme url with `Http -> `Http | `Https -> `Https

let upgrade_http policy url =
  if Web.Policy.upgrade_http_to_https policy && Web.Url.scheme url = `Http then
    let uri =
      Web.Url.uri url |> fun uri -> Uri.with_scheme uri (Some "https")
    in
    Web.Url.of_string
      ~allow_private_network:(Web.Policy.allow_private_network policy)
      (Uri.to_string uri)
  else Ok url

let permissions ~policy input =
  if not (Web.Policy.enabled policy) then []
  else
    match
      Web.Url.of_string
        ~allow_private_network:(Web.Policy.allow_private_network policy)
        (Input.url input)
    with
    | Error _ -> []
    | Ok url -> (
        match upgrade_http policy url with
        | Error _ -> []
        | Ok url ->
            let access =
              Permission.Access.network ~protocol:(protocol_of_url url)
                ~port:(Web.Url.effective_port url)
                ~host:(Web.Url.host url) ()
            in
            [ Permission.Request.of_accesses ~source:name [ access ] ])

let header_value headers name =
  let name = String.lowercase_ascii name in
  Cohttp.Header.to_list headers
  |> List.find_map (fun (key, value) ->
      if String.equal (String.lowercase_ascii key) name then Some value
      else None)

let accept_header = function
  | Input.Markdown ->
      "text/markdown;q=1.0, text/x-markdown;q=0.9, text/plain;q=0.8, \
       text/html;q=0.7, */*;q=0.1"
  | Input.Text ->
      "text/plain;q=1.0, text/markdown;q=0.9, text/html;q=0.8, */*;q=0.1"
  | Input.Html ->
      "text/html;q=1.0, application/xhtml+xml;q=0.9, text/plain;q=0.8, \
       text/markdown;q=0.7, */*;q=0.1"

let cohttp_headers ~policy format =
  Cohttp.Header.of_list
    [
      ("user-agent", Web.Policy.user_agent policy);
      ("accept", accept_header format);
      ("accept-language", "en-US,en;q=0.9");
    ]

let mime_of_content_type content_type =
  match String.split_on_char ';' content_type with
  | [] -> ""
  | mime :: _ -> String.lowercase_ascii (String.trim mime)

let textual_mime mime =
  mime = ""
  || String.starts_with ~prefix:"text/" mime
  || String.equal mime "application/json"
  || String.ends_with ~suffix:"+json" mime
  || String.equal mime "application/xml"
  || String.ends_with ~suffix:"+xml" mime
  || String.equal mime "application/javascript"
  || String.equal mime "application/x-javascript"

let response_code response =
  Cohttp.Code.code_of_status (Cohttp.Response.status response)

let code_text code = string_of_int code

type read_error = Too_large | Io of string

let read_body_limited body ~max_bytes =
  let chunk = Cstruct.create 4096 in
  let buffer = Buffer.create (min max_bytes 4096) in
  let rec loop size =
    match Eio.Flow.single_read body chunk with
    | exception End_of_file -> Ok (Buffer.contents buffer)
    | exception exn -> Error (Io (Printexc.to_string exn))
    | count ->
        let size = size + count in
        if size > max_bytes then Error Too_large
        else (
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop size)
  in
  loop 0

let validate_utf8 text =
  let rec loop index =
    if index >= String.length text then true
    else
      let decoded = String.get_utf_8_uchar text index in
      Uchar.utf_decode_is_valid decoded
      && loop (index + Uchar.utf_decode_length decoded)
  in
  match loop 0 with
  | true -> true
  | false -> false
  | exception Invalid_argument _ -> false

module Output = struct
  type format = Input.format
  type body = { content : string; truncated : bool; omitted_chars : int }

  type status =
    | Fetched of { code : int; code_text : string; body : body }
    | Redirected of { code : int; from_url : Web.Url.t; to_url : Web.Url.t }
    | Http_error of { code : int; code_text : string; preview : body option }

  type t = {
    requested_url : Web.Url.t;
    effective_url : Web.Url.t;
    content_type : string option;
    format : format;
    bytes_read : int;
    duration_ms : int;
    status : status;
  }

  let make ~requested_url ~effective_url ?content_type ~format ~bytes_read
      ~duration_ms ~status () =
    {
      requested_url;
      effective_url;
      content_type;
      format;
      bytes_read;
      duration_ms;
      status;
    }

  let requested_url t = t.requested_url
  let effective_url t = t.effective_url
  let content_type t = t.content_type
  let format t = t.format
  let bytes_read t = t.bytes_read
  let duration_ms t = t.duration_ms
  let status t = t.status

  let body_json body =
    json_obj
      [
        ("content", Json.string body.content);
        ("truncated", Json.bool body.truncated);
        ("omitted_chars", Json.int body.omitted_chars);
      ]

  let status_json = function
    | Fetched { code; code_text; body } ->
        json_obj
          [
            ("kind", Json.string "fetched");
            ("code", Json.int code);
            ("code_text", Json.string code_text);
            ("body", body_json body);
          ]
    | Redirected { code; from_url; to_url } ->
        json_obj
          [
            ("kind", Json.string "redirected");
            ("code", Json.int code);
            ("from_url", Json.string (Web.Url.to_string from_url));
            ("to_url", Json.string (Web.Url.to_string to_url));
          ]
    | Http_error { code; code_text; preview } ->
        json_obj
          [
            ("kind", Json.string "http_error");
            ("code", Json.int code);
            ("code_text", Json.string code_text);
            ( "preview",
              match preview with
              | None -> json_null
              | Some body -> body_json body );
          ]

  let json t =
    json_obj
      [
        ("requested_url", Json.string (Web.Url.to_string (requested_url t)));
        ("effective_url", Json.string (Web.Url.to_string (effective_url t)));
        ( "content_type",
          match content_type t with
          | None -> json_null
          | Some value -> Json.string value );
        ("format", Json.string (Input.format_to_string (format t)));
        ("bytes_read", Json.int (bytes_read t));
        ("duration_ms", Json.int (duration_ms t));
        ("status", status_json (status t));
        ( "truncated",
          Json.bool
            (match status t with
            | Fetched { body; _ } -> body.truncated
            | Http_error { preview = Some body; _ } -> body.truncated
            | Redirected _ | Http_error { preview = None; _ } -> false) );
      ]

  let text t =
    let b = Buffer.create 1024 in
    begin match status t with
    | Fetched { code = _; code_text = _; body } ->
        Buffer.add_string b "Fetched ";
        Buffer.add_string b (Web.Url.to_string (effective_url t));
        Buffer.add_string b " (";
        Buffer.add_string b
          (Option.value (content_type t) ~default:"unknown content-type");
        Buffer.add_string b ", ";
        Buffer.add_string b (Input.format_to_string (format t));
        Buffer.add_string b ", ";
        Buffer.add_string b (string_of_int (bytes_read t));
        Buffer.add_string b " bytes)\n";
        Buffer.add_string b body.content;
        if body.truncated then
          Printf.bprintf b "\n[omitted %d characters]\n" body.omitted_chars
    | Redirected { code; from_url; to_url } ->
        Printf.bprintf b
          "Redirected (%d)\n\
           Original URL: %s\n\
           Redirect URL: %s\n\
           Make a new web_fetch request for the redirect URL if you need that \
           content.\n"
          code
          (Web.Url.to_string from_url)
          (Web.Url.to_string to_url)
    | Http_error { code; code_text; preview } ->
        Printf.bprintf b "HTTP error %d %s for %s\n" code code_text
          (Web.Url.to_string (effective_url t));
        Option.iter (fun body -> Buffer.add_string b body.content) preview
    end;
    Buffer.contents b

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~truncated:
        (match status t with
        | Fetched { body; _ } -> body.truncated
        | Http_error { preview = Some body; _ } -> body.truncated
        | Redirected _ | Http_error { preview = None; _ } -> false)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let body_of_text policy text =
  let content, truncated, omitted_chars =
    Web.truncate_middle ~max_chars:(Web.Policy.max_output_chars policy) text
  in
  Output.{ content; truncated; omitted_chars }

let convert_content format content_type text =
  let mime = mime_of_content_type content_type in
  if String.equal mime "text/html" || String.equal mime "application/xhtml+xml"
  then
    match format with
    | Input.Markdown -> Web.html_to_markdown text
    | Input.Text -> Web.html_to_text text
    | Input.Html -> Web.sanitize_html text
  else text

let should_redirect code = List.mem code [ 301; 302; 303; 307; 308 ]

let redirect_location response =
  header_value (Cohttp.Response.headers response) "location"

type fetch_success =
  | Response of {
      final_url : Web.Url.t;
      response : Cohttp.Response.t;
      content_type : string option;
      body : string;
    }
  | Cross_authority_redirect of {
      code : int;
      from_url : Web.Url.t;
      to_url : Web.Url.t;
      content_type : string option;
    }

type fetch_error =
  | Fetch_too_large of Cohttp.Response.t * string option
  | Fetch_io of string
  | Too_many_redirects
  | Private_address of { host : string; address : string }

type https =
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r

let ipaddr_to_string address = Format.asprintf "%a" Eio.Net.Ipaddr.pp address

let resolved_addresses ~net url =
  let host = Web.Url.host url in
  match
    Eio.Net.getaddrinfo_stream
      ~service:(string_of_int (Web.Url.effective_port url))
      net host
  with
  | [] -> Error (Fetch_io ("DNS resolution returned no addresses for " ^ host))
  | addresses -> Ok addresses
  | exception exn ->
      Error
        (Fetch_io
           ("DNS resolution failed for " ^ host ^ ": " ^ Printexc.to_string exn))

let first_resolved_address ~net ~policy url =
  match resolved_addresses ~net url with
  | Error _ as error -> error
  | Ok addresses -> (
      if Web.Policy.allow_private_network policy then Ok (List.hd addresses)
      else
        match
          List.find_map
            (function
              | `Tcp (address, _) when Web.Url.private_ipaddr address ->
                  Some address
              | `Tcp _ | `Unix _ -> None)
            addresses
        with
        | Some address ->
            Error
              (Private_address
                 { host = Web.Url.host url; address = ipaddr_to_string address })
        | None -> Ok (List.hd addresses))

let fetch_connection ~sw ~net ~(https : https) uri address =
  let raw =
    (Eio.Net.connect ~sw net address
      :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Std.r)
  in
  match Option.map String.lowercase_ascii (Uri.scheme uri) with
  | Some "http" -> raw
  | Some "https" -> https uri raw
  | Some scheme -> invalid_arg ("unsupported web fetch scheme: " ^ scheme)
  | None -> invalid_arg "missing web fetch scheme"

let fetch_http_client ~net ~(https : https) address =
  Cohttp_eio.Client.make_generic (fun ~sw uri ->
      fetch_connection ~sw ~net ~https uri address)

let fetch_once ~sw ~net ~https ~policy ~format url =
  match first_resolved_address ~net ~policy url with
  | Error _ as error -> error
  | Ok address -> (
      let http = fetch_http_client ~net ~https address in
      let response, body =
        Cohttp_eio.Client.call http ~sw
          ~headers:(cohttp_headers ~policy format)
          `GET (Web.Url.uri url)
      in
      let headers = Cohttp.Response.headers response in
      let content_type = header_value headers "content-type" in
      let content_length = header_value headers "content-length" in
      let max_bytes = Web.Policy.max_fetch_bytes policy in
      match content_length with
      | Some value
        when Option.value (int_of_string_opt value) ~default:0 > max_bytes ->
          Error (Fetch_too_large (response, content_type))
      | _ -> (
          match read_body_limited body ~max_bytes with
          | Error Too_large -> Error (Fetch_too_large (response, content_type))
          | Error (Io message) -> Error (Fetch_io message)
          | Ok text -> Ok (response, content_type, text)))

let rec fetch_follow ~sw ~net ~https ~policy ~format ~remaining authority
    current =
  match fetch_once ~sw ~net ~https ~policy ~format current with
  | Error error -> Error (current, error)
  | Ok (response, content_type, body) ->
      let code = response_code response in
      if should_redirect code then
        match redirect_location response with
        | None ->
            Ok (Response { final_url = current; response; content_type; body })
        | Some location -> (
            let target =
              Uri.resolve "" (Web.Url.uri current) (Uri.of_string location)
            in
            match
              Web.Url.of_string
                ~allow_private_network:(Web.Policy.allow_private_network policy)
                (Uri.to_string target)
            with
            | Error _ ->
                Log.debug (fun m ->
                    m
                      "redirect location did not parse, keeping original \
                       response host=%s"
                      (Web.Url.host current));
                Ok
                  (Response
                     { final_url = current; response; content_type; body })
            | Ok target ->
                if not (Web.Url.same_fetch_authority authority target) then
                  Ok
                    (Cross_authority_redirect
                       {
                         code;
                         from_url = current;
                         to_url = target;
                         content_type;
                       })
                else if remaining <= 0 then Error (current, Too_many_redirects)
                else begin
                  Log.debug (fun m ->
                      m "following redirect status=%d to_host=%s to_path=%s"
                        code (Web.Url.host target)
                        (Uri.path (Web.Url.uri target)));
                  fetch_follow ~sw ~net ~https ~policy ~format
                    ~remaining:(remaining - 1) authority target
                end)
      else Ok (Response { final_url = current; response; content_type; body })

let duration_ms ~mono_clock started =
  Mtime.span started (Eio.Time.Mono.now mono_clock) |> Mtime.Span.to_float_ns
  |> fun ns -> max 0 (int_of_float (ns /. 1_000_000.))

let failed ?output kind message = Tool.Result.failed ?output kind message

let run ~sw ~mono_clock ~net ~https ~policy ?(cancelled = fun () -> false) input
    =
  let started = Eio.Time.Mono.now mono_clock in
  if cancelled () then
    Tool.Result.interrupted ~reason:"cancelled before web fetch" ~cancelled:true
      ()
  else if not (Web.Policy.enabled policy) then
    failed `Permission_denied "web tools are disabled"
  else
    match
      Web.Url.of_string
        ~allow_private_network:(Web.Policy.allow_private_network policy)
        (Input.url input)
    with
    | Error error -> failed `Invalid_input (Web.Url.error_message error)
    | Ok requested -> (
        match upgrade_http policy requested with
        | Error error -> failed `Invalid_input (Web.Url.error_message error)
        | Ok effective -> (
            match
              Web.Policy.resolve_timeout_ms policy (Input.timeout_ms input)
            with
            | Error message -> failed `Invalid_input message
            | Ok timeout_ms -> (
                match
                  Eio.Time.Timeout.run_exn
                    (Eio.Time.Timeout.seconds mono_clock
                       (float_of_int timeout_ms /. 1000.))
                    (fun () ->
                      fetch_follow ~sw ~net ~https ~policy
                        ~format:(Input.format input)
                        ~remaining:(Web.Policy.max_redirects policy)
                        effective effective)
                with
                | exception Eio.Time.Timeout ->
                    failed `Timed_out "web fetch timed out"
                | exception exn ->
                    failed `Unavailable
                      ("web fetch failed: " ^ Printexc.to_string exn)
                | Error (_, Fetch_io message) ->
                    failed `Unavailable ("web fetch failed: " ^ message)
                | Error (_url, Private_address { host; address }) ->
                    failed `Permission_denied
                      ("web fetch resolved " ^ host ^ " to private address "
                     ^ address)
                | Error (url, Fetch_too_large (response, content_type)) ->
                    let output =
                      Output.make ~requested_url:requested ~effective_url:url
                        ?content_type ~format:(Input.format input) ~bytes_read:0
                        ~duration_ms:(duration_ms ~mono_clock started)
                        ~status:
                          (Output.Http_error
                             {
                               code = response_code response;
                               code_text = code_text (response_code response);
                               preview = None;
                             })
                        ()
                    in
                    failed ~output `Failed
                      "web fetch response exceeded size limit"
                | Error (url, Too_many_redirects) ->
                    let output =
                      Output.make ~requested_url:requested ~effective_url:url
                        ~format:(Input.format input) ~bytes_read:0
                        ~duration_ms:(duration_ms ~mono_clock started)
                        ~status:
                          (Output.Http_error
                             {
                               code = 0;
                               code_text = "too_many_redirects";
                               preview = None;
                             })
                        ()
                    in
                    failed ~output `Failed
                      "web fetch followed too many redirects"
                | Ok
                    (Cross_authority_redirect
                       { code; from_url; to_url; content_type }) ->
                    let output =
                      Output.make ~requested_url:requested
                        ~effective_url:from_url ?content_type
                        ~format:(Input.format input) ~bytes_read:0
                        ~duration_ms:(duration_ms ~mono_clock started)
                        ~status:(Output.Redirected { code; from_url; to_url })
                        ()
                    in
                    Tool.Result.completed ~output ()
                | Ok (Response { final_url; response; content_type; body }) ->
                    let code = response_code response in
                    Log.info (fun m ->
                        m
                          "web fetch finished host=%s path=%s status=%d \
                           bytes=%d duration_ms=%d"
                          (Web.Url.host final_url)
                          (Uri.path (Web.Url.uri final_url))
                          code (String.length body)
                          (duration_ms ~mono_clock started));
                    let code_text = code_text code in
                    let mime =
                      content_type |> Option.value ~default:""
                      |> mime_of_content_type
                    in
                    if not (textual_mime mime) then
                      failed `Failed
                        ("unsupported fetched content type: "
                        ^ if mime = "" then "unknown" else mime)
                    else if not (validate_utf8 body) then
                      failed `Failed "fetched content is not valid UTF-8"
                    else
                      let converted =
                        convert_content (Input.format input)
                          (Option.value content_type ~default:"")
                          body
                      in
                      let preview = body_of_text policy converted in
                      let status =
                        if code >= 200 && code < 300 then
                          Output.Fetched { code; code_text; body = preview }
                        else
                          Output.Http_error
                            { code; code_text; preview = Some preview }
                      in
                      let output =
                        Output.make ~requested_url:requested
                          ~effective_url:final_url ?content_type
                          ~format:(Input.format input)
                          ~bytes_read:(String.length body)
                          ~duration_ms:(duration_ms ~mono_clock started)
                          ~status ()
                      in
                      if code >= 200 && code < 300 then
                        Tool.Result.completed ~output ()
                      else
                        failed ~output `Failed
                          ("web fetch returned HTTP " ^ string_of_int code))))

let tool ~sw ~mono_clock ~net ~https ~policy () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~policy input)
    ~run:(fun context input ->
      run ~sw ~mono_clock ~net ~https ~policy
        ~cancelled:(fun () -> Tool.Context.cancelled context)
        input)
    ()
