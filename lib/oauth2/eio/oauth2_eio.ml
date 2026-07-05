(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Eio interpreter for low-level OAuth 2.0 requests. *)

let log_src = Logs.Src.create "spice.oauth2" ~doc:"OAuth 2.0 Eio transport"

module Log = (val Logs.src_log log_src : Logs.LOG)

type response = Oauth2.Response.t

module Error = struct
  type transport = [ `Network of string ]
  type t = [ Oauth2.Response.decode_error | `Transport of transport ]

  let pp_transport fmt = function
    | `Network msg -> Format.fprintf fmt "network error: %s" msg

  let pp fmt = function
    | `Transport e -> pp_transport fmt e
    | `Oauth e -> Format.fprintf fmt "OAuth error: %a" Oauth2.Error.pp e
    | `Malformed e ->
        Format.fprintf fmt "malformed OAuth response: %a" Oauth2.pp_malformed e
    | `Http response ->
        Format.fprintf fmt "HTTP error %d: body length %d"
          response.Oauth2.Response.status
          (String.length response.Oauth2.Response.body);
        Option.iter
          (Format.fprintf fmt ", content-type %S")
          (Oauth2.Response.content_type response)
end

let has_header name headers =
  List.exists
    (fun header ->
      let key = fst header in
      String.equal (String.lowercase_ascii key) name)
    headers

let form_headers headers =
  if has_header "content-type" headers then headers
  else ("Content-Type", "application/x-www-form-urlencoded") :: headers

let default_max_response_body_size = 1_048_576

let response_body ~max_response_body_size body =
  if max_response_body_size < 0 then
    Error (`Network "negative response body limit")
  else
    let max_size =
      if max_response_body_size = max_int then max_int
      else max_response_body_size + 1
    in
    match Eio.Buf_read.(parse take_all) ~max_size body with
    | Ok body -> Ok body
    | Error (`Msg msg) -> Error (`Network ("response body read failed: " ^ msg))

let post http_client ~sw
    ?(max_response_body_size = default_max_response_body_size) ~uri
    ?(headers = []) ~body () =
  if max_response_body_size < 0 then
    Error (`Network "negative response body limit")
  else (
    Eio.Switch.check sw;
    let host = Option.value ~default:"<none>" (Uri.host uri) in
    try
      Eio.Switch.run ~name:"oauth2-post" @@ fun request_sw ->
      let headers = Cohttp.Header.of_list (form_headers headers) in
      let body = Cohttp_eio.Body.of_string body in
      let response, body =
        Cohttp_eio.Client.post http_client ~sw:request_sw ~headers ~body uri
      in
      let status =
        Cohttp.Code.code_of_status (Cohttp.Response.status response)
      in
      let headers = Cohttp.Header.to_list (Cohttp.Response.headers response) in
      match response_body ~max_response_body_size body with
      | Error e -> Error e
      | Ok body ->
          Log.info (fun m ->
              m "oauth request finished host=%s status=%d body_bytes=%d" host
                status (String.length body));
          Ok
            {
              Oauth2.Response.status;
              Oauth2.Response.headers;
              Oauth2.Response.body;
            }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
        Log.debug (fun m ->
            m "oauth request failed host=%s error=%s" host
              (Printexc.to_string exn));
        Error (`Network (Printexc.to_string exn)))

let send http_client ~sw ?max_response_body_size request =
  match
    post http_client ~sw ?max_response_body_size
      ~uri:(Oauth2.Request.uri request)
      ~headers:(Oauth2.Request.headers request)
      ~body:(Oauth2.Request.body request)
      ()
  with
  | Error e -> Error (`Transport e)
  | Ok response ->
      Oauth2.Request.decode request response
      |> Result.map_error (fun e -> (e :> Error.t))

type https =
  Uri.t -> [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t -> Tls_eio.t

let make_https () =
  Mirage_crypto_rng_unix.use_default ();
  match Ca_certs.authenticator () with
  | Error (`Msg msg) -> Error (`Tls_error msg)
  | Ok authenticator -> (
      match Tls.Config.client ~authenticator () with
      | Error (`Msg msg) -> Error (`Tls_error msg)
      | Ok default_tls_config ->
          let tls_config uri =
            match Uri.host uri with
            | None -> invalid_arg "HTTPS URI has no host"
            | Some name -> (
                match Ipaddr.of_string name with
                | Ok ip -> (
                    match Tls.Config.client ~authenticator ~ip () with
                    | Ok tls_config -> (tls_config, None)
                    | Error (`Msg msg) ->
                        invalid_arg ("invalid TLS config: " ^ msg))
                | Error _ -> (
                    match Domain_name.of_string name with
                    | Error (`Msg msg) ->
                        invalid_arg ("invalid HTTPS host: " ^ msg)
                    | Ok domain -> (
                        match Domain_name.host domain with
                        | Error (`Msg msg) ->
                            invalid_arg ("invalid HTTPS host: " ^ msg)
                        | Ok host -> (default_tls_config, Some host))))
          in
          let handler uri raw =
            let tls_config, host = tls_config uri in
            Tls_eio.client_of_flow ?host tls_config raw
          in
          Ok handler)

let make_client ?https net = Cohttp_eio.Client.make ~https net

let make_tls_client net =
  match make_https () with
  | Error (`Tls_error msg) -> Error (`Tls_error msg)
  | Ok https -> Ok (make_client ~https net)
