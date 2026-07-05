(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type cancellation = unit -> bool
type accepts = Model.t -> bool
type run = cancelled:cancellation -> Request.t -> (Stream.t, Error.t) result
type t = { provider : Provider.t; accepts : accepts; run : run }

let make ~provider ?accepts ~run () =
  let accepts =
    match accepts with
    | Some accepts -> accepts
    | None -> fun model -> Provider.equal provider (Model.provider model)
  in
  { provider; accepts; run }

let provider t = t.provider
let accepts t model = t.accepts model

let invalid_model t request =
  let requested = Request.model request in
  let message =
    Format.asprintf "client provider %a cannot run model %a" Provider.pp
      t.provider Model.pp requested
  in
  Error (Error.make ~kind:Error.Invalid_request ~provider:t.provider message)

let stream ?(cancelled = fun () -> false) t request =
  if t.accepts (Request.model request) then t.run ~cancelled request
  else invalid_model t request

let response ?cancelled ?on_event t request =
  match stream ?cancelled t request with
  | Error _ as error -> error
  | Ok stream -> (
      match on_event with
      | None -> Stream.collect stream
      | Some f -> Stream.iter_events stream ~f)
