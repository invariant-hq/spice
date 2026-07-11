(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type cancellation = unit -> bool
type accepts = Model.t -> bool

type run =
  cancelled:cancellation ->
  on_event:(Stream.Event.t -> unit) ->
  Request.t ->
  (Response.t, Error.t) result

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

let not_cancelled () = false
let no_event _ = ()

let response ?(cancelled = not_cancelled) ?(on_event = no_event) t request =
  if t.accepts (Request.model request) then t.run ~cancelled ~on_event request
  else invalid_model t request
