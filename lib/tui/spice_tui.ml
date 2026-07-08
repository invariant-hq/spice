(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Startup = struct
  type t = App.startup
  type input = App.input = Empty | Draft of string | Submit of string

  let make ?cwd ?(mode = Spice_protocol.Mode.default) ?session
      ?(input = App.Empty) () =
    { App.cwd; mode; session; input }
end

module Error = struct
  type t = No_tty | Runtime of string

  let message = function
    | No_tty ->
        "interactive terminal required to run the TUI"
    | Runtime message -> message

  let diagnostic t = Spice_diagnostic.make (message t)
end

module Goodbye = Goodbye

type outcome = Runtime.outcome = { last_session : Spice_session.Id.t option }

let run ~stdenv ~startup () =
  match Runtime.run ~stdenv ~startup () with
  | Ok outcome -> Ok outcome
  | Error `No_tty -> Error Error.No_tty
  | Error (`Runtime message) -> Error (Error.Runtime message)
