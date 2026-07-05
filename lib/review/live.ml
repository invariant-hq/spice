(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type review = Review.t

module Request = struct
  type t = int

  let equal = Int.equal
  let pp ppf t = Format.fprintf ppf "request %d" t
end

type load = {
  feature : Feature.t;
  crs : Spice_cr.Occurrence.t list;
  fingerprint : string;
}

(* [Debouncing] waits for the change burst to settle; its deadline is
   extended by further changes and re-armed by early ticks. [Loading] has one
   load in flight; [dirty] records changes seen since it started. [Mutating]
   pauses watching entirely: the mutation completes with a fresh load, which
   also captures any concurrent changes. *)
type state =
  | Idle
  | Debouncing of { request : Request.t; deadline : float }
  | Loading of { request : Request.t; dirty : bool }
  | Mutating of { request : Request.t }

type t = {
  debounce : float;
  review : review;
  loaded_fingerprint : string option;
  state : state;
  next_request : int;
}

let make ?(debounce = 0.5) ~review ~fingerprint () =
  {
    debounce;
    review;
    loaded_fingerprint = Some fingerprint;
    state = Idle;
    next_request = 0;
  }

let review (t : t) = t.review
let fingerprint (t : t) = t.loaded_fingerprint

type event =
  | Fs_changed of { now : float }
  | Tick of { now : float; request : Request.t }
  | Loaded of Request.t * ([ `Unchanged | `Loaded of load ], string) result
  | Review_changed of review

type action =
  | Sleep of { request : Request.t; seconds : float }
  | Load of { request : Request.t; known : string option }
  | Replace of review
  | Error of string

let fresh_request t =
  ({ t with next_request = t.next_request + 1 }, t.next_request)

let start_load t =
  let t, request = fresh_request t in
  ( { t with state = Loading { request; dirty = false } },
    [ Load { request; known = t.loaded_fingerprint } ] )

let step t event =
  match event with
  | Review_changed review -> ({ t with review }, [])
  | Fs_changed { now } -> (
      match t.state with
      | Idle ->
          let t, request = fresh_request t in
          ( {
              t with
              state = Debouncing { request; deadline = now +. t.debounce };
            },
            [ Sleep { request; seconds = t.debounce } ] )
      | Debouncing { request; _ } ->
          (* Extend the deadline; the pending tick re-arms itself. *)
          ( {
              t with
              state = Debouncing { request; deadline = now +. t.debounce };
            },
            [] )
      | Loading { request; dirty = _ } ->
          ({ t with state = Loading { request; dirty = true } }, [])
      | Mutating _ -> (t, []))
  | Tick { now; request } -> (
      match t.state with
      | Debouncing { request = current; deadline }
        when Request.equal current request ->
          if now >= deadline then start_load t
          else
            (* An extended deadline: sleep out the remainder. *)
            ( { t with state = Debouncing { request; deadline } },
              [ Sleep { request; seconds = deadline -. now } ] )
      | Idle | Debouncing _ | Loading _ | Mutating _ -> (t, []))
  | Loaded (request, result) -> (
      match t.state with
      | Loading { request = current; dirty } when Request.equal current request
        -> (
          let continue t actions =
            if dirty then
              let t, more = start_load t in
              (t, actions @ more)
            else ({ t with state = Idle }, actions)
          in
          match result with
          | Ok `Unchanged -> continue { t with state = Idle } []
          | Ok (`Loaded load) ->
              let { feature; crs; fingerprint } = (load : load) in
              let review = Review.refresh t.review ~feature ~crs in
              continue
                {
                  t with
                  review;
                  loaded_fingerprint = Some fingerprint;
                  state = Idle;
                }
                [ Replace review ]
          | Result.Error message ->
              continue { t with state = Idle } [ Error message ])
      | Idle | Debouncing _ | Loading _ | Mutating _ -> (t, []))

let mutation_started t ~fingerprint =
  match t.state with
  | Mutating _ ->
      Result.Error
        (Error.make Error.Busy "a source mutation is already running")
  | Idle | Debouncing _ | Loading _ -> (
      match t.loaded_fingerprint with
      | Some known when String.equal known fingerprint ->
          let t, request = fresh_request t in
          Ok ({ t with state = Mutating { request } }, request)
      | Some _ | None ->
          Result.Error
            (Error.make Error.Stale_snapshot
               "the worktree changed since the review was loaded"))

let mutation_aborted t request =
  match t.state with
  | Mutating { request = current } when Request.equal current request ->
      { t with state = Idle }
  | Idle | Debouncing _ | Loading _ | Mutating _ -> t

let mutation_loaded t request result =
  match t.state with
  | Mutating { request = current } when Request.equal current request -> (
      match result with
      | Ok load ->
          let { feature; crs; fingerprint } = (load : load) in
          let review = Review.refresh t.review ~feature ~crs in
          ( {
              t with
              review;
              loaded_fingerprint = Some fingerprint;
              state = Idle;
            },
            `Replaced review )
      | Result.Error message ->
          ({ t with loaded_fingerprint = None; state = Idle }, `Failed message))
  | Idle | Debouncing _ | Loading _ | Mutating _ -> (t, `Stale)
