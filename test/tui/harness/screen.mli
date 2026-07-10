(** Screen predicates, normalization, and golden-frame formatting. *)

val contains : string -> string -> bool
(** [contains text fragment] reports whether [fragment] occurs in [text]. *)

val has : string -> string -> bool
(** [has fragment screen] reports whether [screen] contains [fragment]. *)

val lacks : string -> string -> bool
(** [lacks fragment screen] reports whether [screen] omits [fragment]. *)

val normalize : project:Project.t -> string -> string
(** [normalize ~project screen] replaces machine-dependent project paths,
    session identifiers, and localhost ports with stable markers. *)

val print : project:Project.t -> string -> unit
(** [print ~project screen] writes the normalized screen with one-based row
    numbers. *)
