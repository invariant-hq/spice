(** Raw terminal input encodings used by both TUI drivers. *)

val enter : string
(** [enter] is the carriage-return encoding of the Enter key. *)

val linefeed : string
(** [linefeed] is the line-feed byte. *)

val ctrl_c : string
(** [ctrl_c] is the Control-C byte. *)

val ctrl_o : string
(** [ctrl_o] is the Control-O byte. *)

val ctrl_r : string
(** [ctrl_r] is the Control-R byte. *)

val ctrl_w : string
(** [ctrl_w] is the Control-W byte. *)

val escape : string
(** [escape] is the Escape byte. *)

val up : string
(** [up] is the terminal's cursor-up sequence. *)

val down : string
(** [down] is the terminal's cursor-down sequence. *)

val left : string
(** [left] is the terminal's cursor-left sequence. *)

val backspace : string
(** [backspace] is the Delete byte commonly sent by Backspace. *)

val tab : string
(** [tab] is the horizontal-tab byte. *)

val bracketed_paste : string -> string
(** [bracketed_paste text] is [text] enclosed by the terminal's bracketed-paste
    start and end sequences. *)
