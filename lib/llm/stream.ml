(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Import

let invalid fn message = invalid_arg' "Spice_llm.Stream" fn message

let reject_empty fn field value =
  if String.is_empty value then invalid fn (field ^ " must not be empty")

let reject_empty_option fn field = function
  | None -> ()
  | Some value -> reject_empty fn field value

module Event = struct
  module Tool_input = struct
    type t = {
      key : string;
      call_id : string option;
      name : string option;
      input_delta : string;
    }

    let make ~key ?call_id ?name ~input_delta () =
      reject_empty "Event.Tool_input.make" "key" key;
      reject_empty_option "Event.Tool_input.make" "call_id" call_id;
      reject_empty_option "Event.Tool_input.make" "name" name;
      reject_empty "Event.Tool_input.make" "input_delta" input_delta;
      { key; call_id; name; input_delta }

    let key t = t.key
    let call_id t = t.call_id
    let name t = t.name
    let input_delta t = t.input_delta
    let equal a b = a = b
  end

  type t =
    | Text_delta of string
    | Reasoning_summary_delta of string
    | Tool_input_delta of Tool_input.t
    | Tool_call of Tool.Call.t
    | Usage of Usage.t

  let text_delta value =
    reject_empty "Event.text_delta" "text" value;
    Text_delta value

  let reasoning_summary_delta value =
    reject_empty "Event.reasoning_summary_delta" "summary" value;
    Reasoning_summary_delta value

  let tool_input_delta delta = Tool_input_delta delta
  let tool_call call = Tool_call call
  let usage usage = Usage usage
end

type item = Event of Event.t | Finished of Response.t | Failed of Error.t

type t = {
  next_item : unit -> item option;
  close_item : unit -> unit;
  mutable closed : bool;
}

let close t =
  if not t.closed then begin
    t.closed <- true;
    t.close_item ()
  end

let close_noerr t = try close t with _ -> ()

let make ?(close = fun () -> ()) next_item =
  { next_item; close_item = close; closed = false }

let of_list ?close items =
  let remaining = ref items in
  make ?close (fun () ->
      match !remaining with
      | [] -> None
      | item :: rest ->
          remaining := rest;
          Some item)

let malformed_stream () =
  Error.make ~kind:Error.Malformed_stream ~phase:Error.Stream
    "stream ended before a terminal item"

let stream_exception exn =
  Error.make ~kind:Error.Transport ~phase:Error.Stream (Printexc.to_string exn)

let next t =
  if t.closed then None
  else
    match t.next_item () with
    | exception exn ->
        close_noerr t;
        Some (Failed (stream_exception exn))
    | None ->
        close t;
        Some (Failed (malformed_stream ()))
    | Some (Finished _ as item) | Some (Failed _ as item) ->
        close t;
        Some item
    | Some (Event _ as item) -> Some item

let use t f =
  match f t with
  | value ->
      close t;
      value
  | exception exn ->
      close_noerr t;
      raise exn

let collect t =
  use t @@ fun t ->
  let rec loop () =
    match next t with
    | None -> Error (malformed_stream ())
    | Some (Event _) -> loop ()
    | Some (Finished response) -> Ok response
    | Some (Failed error) -> Error error
  in
  loop ()

let fold_events t ~init ~f =
  use t @@ fun t ->
  let rec loop acc =
    match next t with
    | None -> Error (malformed_stream ())
    | Some (Event event) -> loop (f acc event)
    | Some (Finished response) -> Ok (acc, response)
    | Some (Failed error) -> Error error
  in
  loop init

let iter_events t ~f =
  match fold_events t ~init:() ~f:(fun () event -> f event) with
  | Ok ((), response) -> Ok response
  | Error error -> Error error
