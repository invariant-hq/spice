(** Fake OpenAI provider scripts shared by both TUI drivers. *)

(** The type for scripted provider replies. *)
type reply =
  | Completion of {
      id : string;
      text : string;
      reasoning : string option;
      output_tokens : int option;
    }
      (** A streamed Responses completion. [reasoning], when present, is sent as
          reasoning-summary deltas before the visible text. *)
  | Stream_hold of {
      id : string;
      text : string;
      reasoning : string option;
      output_tokens : int option;
    }
      (** A completion whose deltas are sent before its named gate is released,
          leaving a stable, observable in-flight frame. *)
  | Tool_call of {
      id : string;
      call_id : string;
      name : string;
      arguments : string;
      output_tokens : int option;
    }
      (** One function call. [arguments] is the JSON argument object encoded as
          a string in the Responses payload. *)
  | Tool_calls of { id : string; calls : (string * string * string) list }
      (** Several function calls in one response. Each tuple is
          [(call_id, name, arguments)]. *)
  | Http of { status : int; body : string }
      (** A plain HTTP response for non-Responses endpoints. *)

type item = private {
  expect_line : string;  (** Exact HTTP request line. *)
  expect : string list;  (** Required request-body fragments. *)
  gate : string option;  (** Optional in-process synchronization gate. *)
  reply : reply;  (** Reply served after expectations and gates succeed. *)
}
(** The type for one expected request and its reply. *)

type t = item list
(** The type for ordered provider scripts. *)

val message :
  ?expect:string list ->
  ?gate:string ->
  ?reasoning:string ->
  ?output_tokens:int ->
  id:string ->
  string ->
  item
(** [message ~id text] expects a Responses request and streams [text]. [expect]
    lists required request-body fragments; [gate] holds the response before it
    starts. *)

val stream_hold :
  ?expect:string list ->
  ?reasoning:string ->
  ?output_tokens:int ->
  gate:string ->
  id:string ->
  string ->
  item
(** [stream_hold ~gate ~id text] streams deltas, waits for [gate], then sends
    the terminal response event. *)

val http :
  ?expect:string list ->
  ?gate:string ->
  line:string ->
  status:int ->
  string ->
  item
(** [http ~line ~status body] expects request line [line] and returns [body]
    with [status]. *)

val tool_call :
  ?expect:string list ->
  ?gate:string ->
  ?output_tokens:int ->
  id:string ->
  call_id:string ->
  name:string ->
  arguments:string ->
  unit ->
  item
(** [tool_call ~id ~call_id ~name ~arguments ()] returns one function-call
    output item. *)

val tool_calls :
  ?expect:string list ->
  ?gate:string ->
  id:string ->
  calls:(string * string * string) list ->
  unit ->
  item
(** [tool_calls ~id ~calls ()] returns several function-call output items in a
    single response. *)

(** {1:low-level Low-level wire format} *)

val sse_deltas : text:string -> reasoning:string option -> string
(** [sse_deltas] encodes reasoning and output text as SSE delta events. *)

val sse_terminal :
  id:string ->
  text:string ->
  reasoning:string option ->
  output_tokens:int option ->
  string
(** [sse_terminal] encodes the terminal Responses completion event. *)

val sse_body :
  id:string ->
  text:string ->
  reasoning:string option ->
  output_tokens:int option ->
  string
(** [sse_body] encodes all delta and terminal events for a completion. *)

val tool_call_sse :
  id:string ->
  call_id:string ->
  name:string ->
  arguments:string ->
  output_tokens:int option ->
  string
(** [tool_call_sse] encodes one function call as a terminal SSE event. *)

val tool_calls_sse :
  id:string -> calls:(string * string * string) list -> string
(** [tool_calls_sse] encodes several function calls as one terminal SSE event.
*)

val http_head :
  ?status:int -> ?content_type:string -> content_length:int -> unit -> string
(** [http_head ~content_length ()] encodes a closing HTTP/1.1 response header.
*)

val http_response : ?status:int -> ?content_type:string -> string -> string
(** [http_response body] prefixes [body] with a matching HTTP response header.
*)

val to_process_line : ?delay_ms:int -> item -> string
(** [to_process_line item] encodes [item] for the external provider process.

    Raises [Invalid_argument] if [item] uses an in-process-only gate or stream
    hold. *)
