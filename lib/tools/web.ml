(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = invalid_arg ("Spice_tools.Web." ^ fn ^ ": " ^ message)
let is_space = function ' ' | '\n' | '\r' | '\t' | '\012' -> true | _ -> false

let trim text =
  let length = String.length text in
  let rec left i =
    if i < length && is_space text.[i] then left (i + 1) else i
  in
  let rec right i = if i >= 0 && is_space text.[i] then right (i - 1) else i in
  let first = left 0 in
  let last = right (length - 1) in
  if last < first then "" else String.sub text first (last - first + 1)

module Domain = struct
  let valid_label label =
    let length = String.length label in
    length > 0 && length <= 63
    &&
    let valid_char = function
      | 'a' .. 'z' | '0' .. '9' | '-' -> true
      | _ -> false
    in
    String.for_all valid_char label
    && label.[0] <> '-'
    && label.[length - 1] <> '-'

  let normalize raw =
    let host = String.lowercase_ascii (trim raw) in
    if host = "" then Error "domain must not be empty"
    else if String.contains host '/' || String.contains host ':' then
      Error "domain must be a hostname, not a URL"
    else if String.contains host '*' || String.contains host '?' then
      Error "wildcard domains are not supported"
    else
      let labels = String.split_on_char '.' host in
      if List.length labels < 2 then
        Error "domain must have at least two labels"
      else if List.for_all valid_label labels then Ok host
      else Error "domain contains invalid characters"
end

module Url = struct
  type error =
    | Invalid_uri of string
    | Unsupported_scheme of string
    | Missing_host
    | Userinfo_not_allowed
    | Fragment_not_allowed
    | Too_long of { max_length : int; actual_length : int }
    | Private_host_not_allowed of string

  let max_length = 2_000

  let error_message = function
    | Invalid_uri message -> "invalid URL: " ^ message
    | Unsupported_scheme scheme -> "unsupported URL scheme: " ^ scheme
    | Missing_host -> "URL must include a host"
    | Userinfo_not_allowed -> "URL must not include username or password"
    | Fragment_not_allowed -> "URL must not include a fragment"
    | Too_long { max_length; actual_length } ->
        Printf.sprintf "URL is too long (%d bytes; maximum %d)" actual_length
          max_length
    | Private_host_not_allowed host ->
        "private or local host is not allowed: " ^ host

  let pp_error ppf error = Format.pp_print_string ppf (error_message error)

  type t = {
    uri : Uri.t;
    text : string;
    scheme : [ `Http | `Https ];
    host : string;
    port : int option;
  }

  let uri t = t.uri
  let to_string t = t.text
  let scheme t = t.scheme
  let host t = t.host
  let port t = t.port

  let effective_port t =
    match t.port with
    | Some port -> port
    | None -> ( match t.scheme with `Http -> 80 | `Https -> 443)

  let origin t =
    let scheme = match t.scheme with `Http -> "http" | `Https -> "https" in
    scheme ^ "://" ^ t.host ^ ":" ^ string_of_int (effective_port t)

  (* A [www.] host and its bare form are distinct authorities: a redirect that
     crosses between them was never the exact host named in the reviewed access,
     so it re-asks rather than being followed silently. *)
  let same_fetch_authority a b =
    a.scheme = b.scheme
    && effective_port a = effective_port b
    && String.equal a.host b.host

  let has_userinfo raw =
    let authority_start =
      match String.index_opt raw ':' with
      | Some scheme_end
        when String.length raw >= scheme_end + 3
             && String.equal (String.sub raw scheme_end 3) "://" ->
          Some (scheme_end + 3)
      | Some _ | None -> None
    in
    match authority_start with
    | None -> false
    | Some start ->
        let stop =
          let rec loop index =
            if index >= String.length raw then index
            else
              match raw.[index] with
              | '/' | '?' | '#' -> index
              | _ -> loop (index + 1)
          in
          loop start
        in
        String.contains (String.sub raw start (stop - start)) '@'

  let ipv4_parts host =
    match String.split_on_char '.' host with
    | [ a; b; c; d ] -> (
        try
          let part value =
            if value = "" then raise Exit;
            let n = int_of_string value in
            if n < 0 || n > 255 then raise Exit;
            n
          in
          Some (part a, part b, part c, part d)
        with _ -> None)
    | _ -> None

  let private_ipv4 a b c =
    a = 0 || a = 10 || a = 127
    || (a = 100 && b >= 64 && b <= 127)
    || (a = 169 && b = 254)
    || (a = 172 && b >= 16 && b <= 31)
    || (a = 192 && b = 0 && c = 2)
    || (a = 192 && b = 0 && c = 0)
    || (a = 192 && b = 88 && c = 99)
    || (a = 192 && b = 168)
    || (a = 198 && b = 51 && c = 100)
    || (a = 198 && (b = 18 || b = 19))
    || (a = 203 && b = 0 && c = 113)
    || a >= 224

  let private_ipv4_host = function
    | Some (a, b, c, _) -> private_ipv4 a b c
    | None -> false

  let private_host host =
    let host = String.lowercase_ascii host in
    String.equal host "localhost"
    || (not (String.contains host '.'))
    ||
    match ipv4_parts host with
    | Some _ as ipv4 -> private_ipv4_host ipv4
    | None ->
        String.equal host "::1"
        || String.starts_with ~prefix:"fc" host
        || String.starts_with ~prefix:"fd" host
        || String.starts_with ~prefix:"fe80" host

  let byte raw index = Char.code raw.[index]

  let private_ipaddr (address : Eio.Net.Ipaddr.v4v6) =
    let raw = (address :> string) in
    match String.length raw with
    | 4 -> private_ipv4 (byte raw 0) (byte raw 1) (byte raw 2)
    | 16 ->
        let first = byte raw 0 in
        let second = byte raw 1 in
        String.equal raw (String.make 16 '\000')
        || String.equal raw
             ("\000\000\000\000\000\000\000\000\000\000"
            ^ "\000\000\000\000\000\001")
        || first land 0xfe = 0xfc
        || (first = 0xfe && second land 0xc0 = 0x80)
        || first = 0xff
        || String.starts_with
             ~prefix:"\000\000\000\000\000\000\000\000\000\000\255\255" raw
           && private_ipv4 (byte raw 12) (byte raw 13) (byte raw 14)
    | _ -> true

  let normalize_uri uri scheme host =
    let uri =
      Uri.with_scheme uri
        (Some (match scheme with `Http -> "http" | `Https -> "https"))
    in
    Uri.with_host uri (Some host) |> fun uri -> Uri.with_fragment uri None

  let of_string ~allow_private_network raw =
    let raw = trim raw in
    let actual_length = String.length raw in
    if actual_length > max_length then
      Error (Too_long { max_length; actual_length })
    else if has_userinfo raw then Error Userinfo_not_allowed
    else
      match Uri.of_string raw with
      | exception exn -> Error (Invalid_uri (Printexc.to_string exn))
      | uri -> (
          match Uri.scheme uri with
          | None -> Error (Unsupported_scheme "")
          | Some raw_scheme -> (
              let raw_scheme = String.lowercase_ascii raw_scheme in
              let scheme =
                match raw_scheme with
                | "http" -> Ok `Http
                | "https" -> Ok `Https
                | scheme -> Error (Unsupported_scheme scheme)
              in
              match scheme with
              | Error _ as error -> error
              | Ok scheme -> (
                  match Uri.host uri with
                  | None | Some "" -> Error Missing_host
                  | Some host ->
                      if Option.is_some (Uri.fragment uri) then
                        Error Fragment_not_allowed
                      else
                        let host = String.lowercase_ascii host in
                        if (not allow_private_network) && private_host host then
                          Error (Private_host_not_allowed host)
                        else
                          let port = Uri.port uri in
                          let uri = normalize_uri uri scheme host in
                          Ok
                            {
                              uri;
                              text = Uri.to_string uri;
                              scheme;
                              host;
                              port;
                            })))

  let jsont =
    Jsont.Base.string
      (Jsont.Base.map ~kind:"web URL"
         ~dec:
           (Jsont.Base.dec_result (fun text ->
                match of_string ~allow_private_network:false text with
                | Ok url -> Ok url
                | Error error -> Error (error_message error)))
         ~enc:(Jsont.Base.enc_result (fun url -> Ok (to_string url)))
         ())
end

module Policy = struct
  type search_backend = Disabled | Brave of { api_key : string }

  type t = {
    enabled : bool;
    allow_private_network : bool;
    upgrade_http_to_https : bool;
    max_fetch_bytes : int;
    max_output_chars : int;
    default_timeout_ms : int;
    max_timeout_ms : int;
    max_redirects : int;
    user_agent : string;
    search_backend : search_backend;
  }

  let default_user_agent = "spice/0 (+https://github.com/invariant-hq/spice)"

  let make ?(enabled = false) ?(allow_private_network = false)
      ?(upgrade_http_to_https = true) ?(max_fetch_bytes = 5 * 1024 * 1024)
      ?(max_output_chars = 100_000) ?(default_timeout_ms = 30_000)
      ?(max_timeout_ms = 120_000) ?(max_redirects = 10)
      ?(user_agent = default_user_agent) ?(search_backend = Disabled) () =
    if max_fetch_bytes < 0 then
      invalid "Policy.make" "max_fetch_bytes must be non-negative";
    if max_output_chars < 0 then
      invalid "Policy.make" "max_output_chars must be non-negative";
    if default_timeout_ms <= 0 then
      invalid "Policy.make" "default_timeout_ms must be positive";
    if max_timeout_ms <= 0 then
      invalid "Policy.make" "max_timeout_ms must be positive";
    if default_timeout_ms > max_timeout_ms then
      invalid "Policy.make" "default_timeout_ms must not exceed max_timeout_ms";
    if max_redirects < 0 then
      invalid "Policy.make" "max_redirects must be non-negative";
    if user_agent = "" then invalid "Policy.make" "user_agent must not be empty";
    {
      enabled;
      allow_private_network;
      upgrade_http_to_https;
      max_fetch_bytes;
      max_output_chars;
      default_timeout_ms;
      max_timeout_ms;
      max_redirects;
      user_agent;
      search_backend;
    }

  let enabled t = t.enabled
  let allow_private_network t = t.allow_private_network
  let upgrade_http_to_https t = t.upgrade_http_to_https
  let max_fetch_bytes t = t.max_fetch_bytes
  let max_output_chars t = t.max_output_chars
  let default_timeout_ms t = t.default_timeout_ms
  let max_timeout_ms t = t.max_timeout_ms
  let max_redirects t = t.max_redirects
  let user_agent t = t.user_agent
  let search_backend t = t.search_backend

  let resolve_timeout_ms t = function
    | None -> Ok t.default_timeout_ms
    | Some timeout_ms when timeout_ms <= 0 ->
        Error "timeout_ms must be positive"
    | Some timeout_ms when timeout_ms > t.max_timeout_ms ->
        Error ("timeout_ms must be at most " ^ string_of_int t.max_timeout_ms)
    | Some timeout_ms -> Ok timeout_ms
end

let truncate_middle ~max_chars text =
  let length = String.length text in
  if length <= max_chars then (text, false, 0)
  else if max_chars <= 32 then
    let kept = max 0 max_chars in
    (String.sub text 0 kept, true, length - kept)
  else
    let marker = "\n[... omitted ...]\n" in
    let marker_length = String.length marker in
    let budget = max 0 (max_chars - marker_length) in
    let head = budget / 2 in
    let tail = budget - head in
    let omitted = length - head - tail in
    ( String.sub text 0 head ^ marker ^ String.sub text (length - tail) tail,
      true,
      omitted )

let remove_active_blocks html =
  let tags =
    [
      "script"; "style"; "noscript"; "iframe"; "object"; "embed"; "meta"; "link";
    ]
  in
  let find_sub ~sub text start =
    let sub_length = String.length sub in
    let text_length = String.length text in
    let rec loop i =
      if i + sub_length > text_length then None
      else if String.equal sub (String.sub text i sub_length) then Some i
      else loop (i + 1)
    in
    loop start
  in
  let rec strip_one tag html lower =
    match find_sub ~sub:("<" ^ tag) lower 0 with
    | None -> html
    | Some start -> (
        let close = "</" ^ tag ^ ">" in
        match find_sub ~sub:close lower start with
        | None ->
            let stop =
              match find_sub ~sub:">" lower start with
              | None -> String.length html - 1
              | Some stop -> stop
            in
            let next =
              String.sub html 0 start ^ String.drop_first (stop + 1) html
            in
            strip_one tag next (String.lowercase_ascii next)
        | Some close_start ->
            let stop = close_start + String.length close in
            let next = String.sub html 0 start ^ String.drop_first stop html in
            strip_one tag next (String.lowercase_ascii next))
  in
  List.fold_left
    (fun html tag -> strip_one tag html (String.lowercase_ascii html))
    html tags

let decode_entity = function
  | "amp" -> "&"
  | "lt" -> "<"
  | "gt" -> ">"
  | "quot" -> "\""
  | "apos" -> "'"
  | "nbsp" -> " "
  | entity -> "&" ^ entity ^ ";"

let decode_entities text =
  let length = String.length text in
  let b = Buffer.create length in
  let rec loop i =
    if i >= length then ()
    else if text.[i] = '&' then (
      match String.index_from_opt text i ';' with
      | None ->
          Buffer.add_char b text.[i];
          loop (i + 1)
      | Some semi when semi - i > 16 ->
          Buffer.add_char b text.[i];
          loop (i + 1)
      | Some semi ->
          let entity = String.sub text (i + 1) (semi - i - 1) in
          Buffer.add_string b (decode_entity entity);
          loop (semi + 1))
    else (
      Buffer.add_char b text.[i];
      loop (i + 1))
  in
  loop 0;
  Buffer.contents b

let strip_tags ?(markdown = false) html =
  let html = remove_active_blocks html in
  let length = String.length html in
  let b = Buffer.create length in
  let rec loop i in_tag tag =
    if i >= length then ()
    else if in_tag then
      if html.[i] = '>' then (
        let tag = String.lowercase_ascii (trim tag) in
        let tag_name =
          match String.split_on_char ' ' tag with
          | [] -> tag
          | name :: _ -> name
        in
        (if markdown then
           match tag_name with
           | "br" | "/p" | "/div" | "/li" -> Buffer.add_char b '\n'
           | "p" | "div" -> Buffer.add_char b '\n'
           | "li" -> Buffer.add_string b "\n- "
           | "h1" -> Buffer.add_string b "\n# "
           | "h2" -> Buffer.add_string b "\n## "
           | "h3" -> Buffer.add_string b "\n### "
           | "/h1" | "/h2" | "/h3" -> Buffer.add_char b '\n'
           | _ -> ());
        loop (i + 1) false "")
      else loop (i + 1) true (tag ^ String.make 1 html.[i])
    else if html.[i] = '<' then loop (i + 1) true ""
    else (
      Buffer.add_char b html.[i];
      loop (i + 1) false "")
  in
  loop 0 false "";
  Buffer.contents b |> decode_entities |> trim

let html_to_text html = strip_tags html
let html_to_markdown html = strip_tags ~markdown:true html
let sanitize_html = remove_active_blocks
