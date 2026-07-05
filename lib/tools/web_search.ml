(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let log_src = Logs.Src.create "spice.tools.web_search" ~doc:"Web search tool"

module Log = (val Logs.src_log log_src : Logs.LOG)

let name = "web_search"
let description = Spice_prompts.Tools.web_search

let json_obj fields =
  Json.object'
    (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)

let json_null = Json.null ()

let json_string_option = function
  | None -> json_null
  | Some value -> Json.string value

module Input = struct
  type freshness = Anytime | Day | Week | Month | Year

  type t = {
    query : string;
    limit : int;
    allowed_domains : string list;
    blocked_domains : string list;
    freshness : freshness;
  }

  let max_query_length = 500
  let max_limit = 20

  let freshness_to_string = function
    | Anytime -> "anytime"
    | Day -> "day"
    | Week -> "week"
    | Month -> "month"
    | Year -> "year"

  let freshness_of_string = function
    | "anytime" -> Anytime
    | "day" -> Day
    | "week" -> Week
    | "month" -> Month
    | "year" -> Year
    | freshness -> invalid_arg ("unknown freshness: " ^ freshness)

  let normalize_domains field domains =
    List.map
      (fun domain ->
        match Web.Domain.normalize domain with
        | Ok domain -> domain
        | Error message -> invalid_arg (field ^ ": " ^ message))
      domains

  let make ?(limit = 5) ?(allowed_domains = []) ?(blocked_domains = [])
      ?(freshness = Anytime) query =
    let query = String.trim query in
    if String.is_empty query then invalid_arg "query must not be empty";
    if String.length query > max_query_length then
      invalid_arg
        ("query must be at most " ^ string_of_int max_query_length ^ " bytes");
    if String.contains query '\000' then
      invalid_arg "query must not contain NUL";
    if limit < 1 || limit > max_limit then
      invalid_arg ("limit must be between 1 and " ^ string_of_int max_limit);
    {
      query;
      limit;
      allowed_domains = normalize_domains "allowed_domains" allowed_domains;
      blocked_domains = normalize_domains "blocked_domains" blocked_domains;
      freshness;
    }

  let make_json query limit allowed_domains blocked_domains freshness =
    decode_invalid_arg (fun () ->
        let limit = Option.value limit ~default:5 in
        let allowed_domains = Option.value allowed_domains ~default:[] in
        let blocked_domains = Option.value blocked_domains ~default:[] in
        let freshness =
          Option.value
            (Option.map freshness_of_string freshness)
            ~default:Anytime
        in
        make ~limit ~allowed_domains ~blocked_domains ~freshness query)

  let query t = t.query
  let limit t = t.limit
  let allowed_domains t = t.allowed_domains
  let blocked_domains t = t.blocked_domains
  let freshness t = t.freshness

  let codec =
    Jsont.Object.map ~kind:"web_search input" make_json
    |> Jsont.Object.mem "query" Jsont.string ~enc:query
    |> Jsont.Object.opt_mem "limit" Jsont.int ~enc:(fun t -> Some (limit t))
    |> Jsont.Object.opt_mem "allowed_domains" (Jsont.list Jsont.string)
         ~enc:(fun t -> Some (allowed_domains t))
    |> Jsont.Object.opt_mem "blocked_domains" (Jsont.list Jsont.string)
         ~enc:(fun t -> Some (blocked_domains t))
    |> Jsont.Object.opt_mem "freshness" Jsont.string ~enc:(fun t ->
        Some (freshness_to_string (freshness t)))
    |> Jsont.Object.error_unknown |> Jsont.Object.finish

  let schema =
    json_obj
      [
        ("type", Json.string "object");
        ( "properties",
          json_obj
            [
              ( "query",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "description",
                      Json.string
                        "Search query to send to the configured web backend." );
                  ] );
              ( "limit",
                json_obj
                  [
                    ("type", Json.string "integer");
                    ("minimum", Json.int 1);
                    ("maximum", Json.int max_limit);
                    ( "description",
                      Json.string
                        "Maximum number of results to return. Defaults to 5." );
                  ] );
              ( "allowed_domains",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", json_obj [ ("type", Json.string "string") ]);
                    ( "description",
                      Json.string
                        "Optional list of domain names to allow in returned \
                         URLs." );
                  ] );
              ( "blocked_domains",
                json_obj
                  [
                    ("type", Json.string "array");
                    ("items", json_obj [ ("type", Json.string "string") ]);
                    ( "description",
                      Json.string
                        "Optional list of domain names to exclude from \
                         returned URLs." );
                  ] );
              ( "freshness",
                json_obj
                  [
                    ("type", Json.string "string");
                    ( "enum",
                      Json.list
                        [
                          Json.string "anytime";
                          Json.string "day";
                          Json.string "week";
                          Json.string "month";
                          Json.string "year";
                        ] );
                    ( "description",
                      Json.string
                        "Preferred freshness window. Defaults to anytime." );
                  ] );
            ] );
        ("required", Json.list [ Json.string "query" ]);
        ("additionalProperties", Json.bool false);
      ]

  let contract = Tool.Input.make codec ~schema
  let decode json = Tool.Input.decode contract json
end

let protocol_of_uri uri =
  match Option.map String.lowercase_ascii (Uri.scheme uri) with
  | Some "http" -> Some `Http
  | Some "https" -> Some `Https
  | Some protocol -> Some (`Other protocol)
  | None -> None

let default_port = function `Http -> 80 | `Https -> 443 | `Other _ -> 443

let backend_access uri =
  match (Uri.host uri, protocol_of_uri uri) with
  | Some host, Some protocol ->
      let port = Option.value (Uri.port uri) ~default:(default_port protocol) in
      Some (Permission.Access.network ~protocol ~port ~host ())
  | None, Some _ | Some _, None | None, None -> None

let backend_uri = function
  | Web.Policy.Disabled -> None
  | Web.Policy.Brave _ -> Some (Uri.of_string "https://api.search.brave.com")

let permissions ~policy input =
  if (not (Web.Policy.enabled policy)) || String.is_empty (Input.query input)
  then []
  else
    Option.bind (backend_uri (Web.Policy.search_backend policy)) backend_access
    |> Option.map (fun access ->
        Permission.Request.of_accesses ~source:name [ access ])
    |> Option.to_list

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
        else begin
          Buffer.add_string buffer
            (Cstruct.to_string (Cstruct.sub chunk 0 count));
          loop size
        end
  in
  loop 0

let response_code response =
  Cohttp.Code.code_of_status (Cohttp.Response.status response)

let duration_ms ~mono_clock started =
  Mtime.span started (Eio.Time.Mono.now mono_clock) |> Mtime.Span.to_float_ns
  |> fun ns -> max 0 (int_of_float (ns /. 1_000_000.))

module Output = struct
  type backend = Brave

  type result = {
    title : string;
    url : Web.Url.t;
    snippet : string;
    published : string option;
    source : string option;
  }

  type t = {
    query : string;
    backend : backend;
    results : result list;
    duration_ms : int;
  }

  let make ~query ~backend ~results ~duration_ms () =
    { query; backend; results; duration_ms }

  let query t = t.query
  let backend t = t.backend
  let results t = t.results
  let duration_ms t = t.duration_ms
  let backend_to_string = function Brave -> "brave"

  let result_json result =
    json_obj
      [
        ("title", Json.string result.title);
        ("url", Json.string (Web.Url.to_string result.url));
        ("snippet", Json.string result.snippet);
        ("published", json_string_option result.published);
        ("source", json_string_option result.source);
      ]

  let json t =
    json_obj
      [
        ("query", Json.string (query t));
        ("backend", Json.string (backend_to_string (backend t)));
        ("duration_ms", Json.int (duration_ms t));
        ("results", Json.list (List.map result_json (results t)));
      ]

  let text t =
    match results t with
    | [] ->
        Printf.sprintf "No web search results for %S via %s." (query t)
          (backend_to_string (backend t))
    | results ->
        let b = Buffer.create 1024 in
        Printf.bprintf b "Web search results for %S via %s (%d ms)\n" (query t)
          (backend_to_string (backend t))
          (duration_ms t);
        List.iteri
          (fun index result ->
            Printf.bprintf b "\n%d. %s\n%s\n" (index + 1) result.title
              (Web.Url.to_string result.url);
            if not (String.is_empty result.snippet) then
              Printf.bprintf b "%s\n" result.snippet;
            Option.iter (Printf.bprintf b "Published: %s\n") result.published;
            Option.iter (Printf.bprintf b "Source: %s\n") result.source)
          results;
        Buffer.contents b

  let type_id : t Type.Id.t = Type.Id.make ()

  let encode t =
    Tool.Output.make ~text:(text t) ~json:(json t)
      ~value:(Tool.Output.pack type_id t)
      ()

  let of_tool_output output = Tool.Output.value type_id output
end

let freshness_query = function
  | Input.Anytime -> None
  | Input.Day -> Some "pd"
  | Input.Week -> Some "pw"
  | Input.Month -> Some "pm"
  | Input.Year -> Some "py"

let brave_headers ~policy ~api_key =
  Cohttp.Header.of_list
    [
      ("accept", "application/json");
      ("user-agent", Web.Policy.user_agent policy);
      ("x-subscription-token", api_key);
    ]

let domain_matches domain host =
  String.equal host domain || String.ends_with ~suffix:("." ^ domain) host

let allowed_by_domains input url =
  let host = Web.Url.host url in
  let allowed = Input.allowed_domains input in
  let blocked = Input.blocked_domains input in
  let allowed_ok =
    match allowed with
    | [] -> true
    | domains -> List.exists (fun domain -> domain_matches domain host) domains
  in
  allowed_ok
  && not (List.exists (fun domain -> domain_matches domain host) blocked)

let brave_query input =
  let domain_terms =
    match Input.allowed_domains input with
    | [] -> []
    | domains ->
        [
          "("
          ^ String.concat " OR "
              (List.map (fun domain -> "site:" ^ domain) domains)
          ^ ")";
        ]
  in
  let blocked_terms =
    List.map (fun domain -> "-site:" ^ domain) (Input.blocked_domains input)
  in
  String.concat " " ((Input.query input :: domain_terms) @ blocked_terms)

let object_field name = function
  | Jsont.Object (fields, _) -> Option.map snd (Json.find_mem name fields)
  | Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
  | Jsont.Array _ ->
      None

let string_field name json =
  match object_field name json with
  | Some (Jsont.String (value, _)) -> Some value
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.Object _
      | Jsont.Array _ )
  | None ->
      None

let array_field name json =
  match object_field name json with
  | Some (Jsont.Array (items, _)) -> Some items
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Object _ )
  | None ->
      None

let nested_object_field name json =
  match object_field name json with
  | Some (Jsont.Object _ as object_) -> Some object_
  | Some
      ( Jsont.Null _ | Jsont.Bool _ | Jsont.Number _ | Jsont.String _
      | Jsont.Array _ )
  | None ->
      None

let source_of_result result url =
  match
    Option.bind (nested_object_field "profile" result) (string_field "name")
  with
  | Some source when not (String.is_empty source) -> Some source
  | Some _ | None -> Some (Web.Url.host url)

let brave_result input item =
  match (string_field "title" item, string_field "url" item) with
  | Some title, Some raw_url -> (
      match Web.Url.of_string ~allow_private_network:false raw_url with
      | Error _ -> None
      | Ok url ->
          if not (allowed_by_domains input url) then None
          else
            let snippet =
              match string_field "description" item with
              | Some value -> Web.html_to_text value
              | None -> ""
            in
            let published = string_field "age" item in
            Some
              Output.
                {
                  title = Web.html_to_text title;
                  url;
                  snippet;
                  published;
                  source = source_of_result item url;
                })
  | Some _, None | None, Some _ | None, None -> None

let parse_brave_results input body =
  match Jsont_bytesrw.decode_string Jsont.json body with
  | Error message -> Error ("invalid search backend JSON: " ^ message)
  | Ok json -> (
      match
        Option.bind (nested_object_field "web" json) (array_field "results")
      with
      | None -> Ok []
      | Some results ->
          Ok
            (results
            |> List.filter_map (brave_result input)
            |> List.take (Input.limit input)))

let brave_uri input =
  let params =
    [
      ("q", brave_query input);
      ("count", string_of_int (Input.limit input));
      ("text_decorations", "false");
    ]
  in
  let params =
    match freshness_query (Input.freshness input) with
    | None -> params
    | Some freshness -> ("freshness", freshness) :: params
  in
  Uri.of_string "https://api.search.brave.com/res/v1/web/search" |> fun uri ->
  Uri.add_query_params' uri params

let run_brave ~sw ~http ~policy ~api_key input =
  let response, body =
    Cohttp_eio.Client.call http ~sw
      ~headers:(brave_headers ~policy ~api_key)
      `GET (brave_uri input)
  in
  let code = response_code response in
  match
    read_body_limited body ~max_bytes:(Web.Policy.max_fetch_bytes policy)
  with
  | Error Too_large -> Error "web search backend response exceeded size limit"
  | Error (Io message) -> Error ("web search backend read failed: " ^ message)
  | Ok body when code < 200 || code >= 300 ->
      let preview, _, _ = Web.truncate_middle ~max_chars:500 body in
      Error
        ("web search backend returned HTTP " ^ string_of_int code ^ ": "
       ^ preview)
  | Ok body -> parse_brave_results input body

let failed ?output kind message = Tool.Result.failed ?output kind message

let run ~sw ~mono_clock ~http ~policy ?(cancelled = fun () -> false) input =
  let started = Eio.Time.Mono.now mono_clock in
  if cancelled () then
    Tool.Result.interrupted ~reason:"cancelled before web search"
      ~cancelled:true ()
  else if not (Web.Policy.enabled policy) then
    failed `Permission_denied "web tools are disabled"
  else
    match Web.Policy.search_backend policy with
    | Web.Policy.Disabled ->
        failed `Unavailable "web search backend is disabled"
    | Web.Policy.Brave { api_key } -> (
        match
          Eio.Time.Timeout.run_exn
            (Eio.Time.Timeout.seconds mono_clock
               (float_of_int (Web.Policy.default_timeout_ms policy) /. 1000.))
            (fun () -> run_brave ~sw ~http ~policy ~api_key input)
        with
        | exception Eio.Time.Timeout -> failed `Timed_out "web search timed out"
        | exception exn ->
            failed `Unavailable ("web search failed: " ^ Printexc.to_string exn)
        | Error message -> failed `Failed message
        | Ok results ->
            let duration = duration_ms ~mono_clock started in
            Log.info (fun m ->
                m "web search finished backend=brave results=%d duration_ms=%d"
                  (List.length results) duration);
            let output =
              Output.make ~query:(Input.query input) ~backend:Output.Brave
                ~results ~duration_ms:duration ()
            in
            Tool.Result.completed ~output ())

let tool ~sw ~mono_clock ~http ~policy () =
  Tool.make ~name ~description ~input:Input.contract ~output:Output.encode
    ~permissions:(fun input -> permissions ~policy input)
    ~run:(fun context input ->
      run ~sw ~mono_clock ~http ~policy
        ~cancelled:(fun () -> Tool.Context.cancelled context)
        input)
    ()
