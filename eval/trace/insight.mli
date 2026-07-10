(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** Structured deterministic observations over a {!Trace.t}.

    An {!t} is one observation a detector made about a run — a repeated call, a
    failure streak, an unchanged re-read, a shell-family breakdown. Detectors
    are pure and deterministic: the same trace yields the same insights in the
    same order. Insight counts are diagnostic, never decision metrics — a
    detector keys on syntactic identity, so a prompt change can zero it without
    changing anything real. *)

(** {1:insights Insights} *)

(** Detector confidence in the observation's importance. *)
type severity =
  | Info  (** A neutral breakdown, not itself a problem. *)
  | Minor  (** A small inefficiency worth noting. *)
  | Major  (** A strong signal of wasted work or flailing. *)

type t = {
  detector : string;  (** The detector that produced this observation. *)
  severity : severity;  (** The observation's severity. *)
  steps : int * int;
      (** The inclusive [(first, last)] step-index range the observation spans.
      *)
  message : string;  (** A one-line human-readable summary. *)
  evidence : string;  (** Compact supporting detail (paths, a histogram). *)
  waste_tokens : int option;
      (** An estimate of wasted tokens, when the detector can attribute one. For
          byte-oriented detectors this is a result-byte count used as a token
          proxy. *)
}
(** The type for one structured observation. *)

val severity_to_string : severity -> string
(** [severity_to_string s] is the stable lowercase spelling of [s]. *)

val pp_severity : Format.formatter -> severity -> unit
(** [pp_severity ppf s] formats {!severity_to_string}[ s]. *)

val jsont : t Jsont.t
(** [jsont] maps insights to JSON objects. *)

(** {1:detectors Detectors} *)

type detector = Trace.t -> t list
(** The type for a detector: a pure function from a trace to its observations,
    in deterministic order. *)

val builtin : (string * detector) list
(** [builtin] are the named detectors, in run order:

    - [repeated-call]: calls with identical name and arguments run two or more
      times. Waste is the result bytes of the repeats beyond the first.
      {!Minor}, {!Major} at four or more.
    - [failure-streak]: three or more consecutive failures of the same tool.
      {!Major}.
    - [reread-unchanged]: a [read_file] of a path already read with no
      intervening change. Waste is the re-read's result bytes. {!Minor}.
    - [shell-family-histogram]: fires once when any [shell] call exists, with
      the command-family histogram as evidence. {!Info}. *)

val detect : (string * detector) list -> Trace.t -> t list
(** [detect detectors trace] runs each detector in [detectors] over [trace] and
    concatenates their observations in list order. *)
