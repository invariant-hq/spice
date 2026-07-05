(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

(* Shared codec and stable-text machinery for the structural enums owned by
   [Access]: [kind], [path_op], and [network_protocol]. [access.ml] and
   [policy.ml] both consume these, so the persisted access form and the matcher
   rule form cannot silently disagree about how an enum encodes.

   Library-private: there is no [codec.mli], and [spice_permission.ml] does not
   re-export this module, so it never reaches the public API. It depends only on
   [Import] and [Jsont], keeping a clean nominal DAG below [access.ml].

   Enum validity (a non-empty [`Other] protocol name) is enforced by the
   per-module construction validators ([Access.network], [Rule.network_host]),
   which run on every decode path; this codec only translates the vocabulary. *)

let stable_field text = string_of_int (String.length text) ^ ":" ^ text

let stable_option f = function
  | None -> "none"
  | Some value -> "some:" ^ f value

let stable_kind = function
  | `Read -> "read"
  | `Write -> "write"
  | `Command -> "command"
  | `Network -> "network"
  | `Custom -> "custom"

let stable_path_op = function
  | `Read -> "read"
  | `Create -> "create"
  | `Modify -> "modify"
  | `Delete -> "delete"

let stable_protocol = function
  | `Http -> "http"
  | `Https -> "https"
  | `Ssh -> "ssh"
  | `Tcp -> "tcp"
  | `Udp -> "udp"
  | `Other protocol -> "other:" ^ stable_field protocol

let kind_jsont : [ `Read | `Write | `Command | `Network | `Custom ] Jsont.t =
  Jsont.enum ~kind:"permission access kind"
    [
      ("read", `Read);
      ("write", `Write);
      ("command", `Command);
      ("network", `Network);
      ("custom", `Custom);
    ]

let path_op_jsont : [ `Read | `Create | `Modify | `Delete ] Jsont.t =
  Jsont.enum ~kind:"path operation"
    [
      ("read", `Read);
      ("create", `Create);
      ("modify", `Modify);
      ("delete", `Delete);
    ]

let builtin_protocol_of_string = function
  | "http" -> Ok `Http
  | "https" -> Ok `Https
  | "ssh" -> Ok `Ssh
  | "tcp" -> Ok `Tcp
  | "udp" -> Ok `Udp
  | protocol -> Error ("unknown network protocol: " ^ protocol)

let builtin_protocol_to_string = function
  | `Http -> Ok "http"
  | `Https -> Ok "https"
  | `Ssh -> Ok "ssh"
  | `Tcp -> Ok "tcp"
  | `Udp -> Ok "udp"
  | `Other _ -> Error "custom network protocols encode as objects"

let builtin_protocol_jsont :
    [ `Http | `Https | `Ssh | `Tcp | `Udp | `Other of string ] Jsont.t =
  Jsont.Base.string
    (Jsont.Base.map ~kind:"network protocol"
       ~dec:(Jsont.Base.dec_result builtin_protocol_of_string)
       ~enc:(Jsont.Base.enc_result builtin_protocol_to_string)
       ())

let other_protocol_jsont :
    [ `Http | `Https | `Ssh | `Tcp | `Udp | `Other of string ] Jsont.t =
  let make tag name =
    if not (String.equal tag "other") then
      decode_error "unknown network protocol object";
    `Other name
  in
  Jsont.Object.map ~kind:"custom network protocol" make
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun _ -> "other")
  |> Jsont.Object.mem "name" Jsont.string ~enc:(function
    | `Other name -> name
    | `Http | `Https | `Ssh | `Tcp | `Udp -> assert false)
  |> Jsont.Object.error_unknown |> Jsont.Object.finish

let network_protocol_jsont :
    [ `Http | `Https | `Ssh | `Tcp | `Udp | `Other of string ] Jsont.t =
  Jsont.any ~kind:"network protocol" ~dec_string:builtin_protocol_jsont
    ~dec_object:other_protocol_jsont
    ~enc:(function
      | `Other _ -> other_protocol_jsont
      | `Http | `Https | `Ssh | `Tcp | `Udp -> builtin_protocol_jsont)
    ()
