(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The impure builder for the settings screen's facts (doc/plans/tui-next.md,
    "tui-next builds its own snapshot from host calls").

    The {!Settings_screen} is pure: it renders the {!Settings_screen.facts} this
    module assembles from the host views — the config field inventory, the
    read-only status sheet, the session usage, and the skills snapshot. The
    runtime calls {!assemble} when the screen opens and re-calls it after each
    write so the screen reflects the persisted state rather than optimistic edits
    (doc/plans/tui-next-surfaces.md §Sequencing 4). This is the one impure
    builder; the screen itself reads no host, config, or filesystem. *)

val assemble :
  stdenv:Eio_unix.Stdenv.base ->
  host:Spice_host.Host.t ->
  session:Spice_session.t option ->
  Settings_screen.facts
(** [assemble ~stdenv ~host ~session] reads the four tabs' facts from [host]'s
    effective config and its skill and account snapshots.

    [host] must carry the current on-disk config — the runtime reloads it before
    each call so a just-persisted write is visible. [session] is the active
    session, whose metrics and metadata feed the usage tab and whose id the
    status tab copies; [None] renders the [no turns yet] usage state and drops
    the copyable id. Reading skills and account status touches the filesystem;
    everything else is a pure read over the config snapshot. *)
