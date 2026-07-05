(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module W = Spice_workspace

let default_max_files = 1024
let default_max_lines = 50_000

(* The anchor vocabulary. Words are letters-only and capitalized so a word
   pair matches the model-visible anchor shape [^[A-Z][a-zA-Z]*$]. None of
   the words is a concatenation of two others, so pairs decode uniquely. *)
let words =
  [|
    "Apple";
    "Banana";
    "Cherry";
    "Mango";
    "Lemon";
    "Peach";
    "Plum";
    "Grape";
    "Melon";
    "Berry";
    "Olive";
    "Fig";
    "Kiwi";
    "Papaya";
    "Guava";
    "Lime";
    "Coconut";
    "Apricot";
    "Cedar";
    "Maple";
    "Willow";
    "Aspen";
    "Birch";
    "Spruce";
    "Juniper";
    "Laurel";
    "Poplar";
    "Walnut";
    "Hazel";
    "Rowan";
    "Alder";
    "Elm";
    "Falcon";
    "Heron";
    "Sparrow";
    "Robin";
    "Swallow";
    "Crane";
    "Pelican";
    "Osprey";
    "Raven";
    "Magpie";
    "Plover";
    "Finch";
    "Wren";
    "Owl";
    "Eagle";
    "Condor";
    "Otter";
    "Badger";
    "Marten";
    "Lynx";
    "Ocelot";
    "Jaguar";
    "Panther";
    "Cougar";
    "Bison";
    "Elk";
    "Moose";
    "Caribou";
    "Gazelle";
    "Impala";
    "Zebra";
    "Okapi";
    "Tapir";
    "Lemur";
    "Gibbon";
    "Macaque";
    "Baboon";
    "Walrus";
    "Seal";
    "Dolphin";
    "Orca";
    "Beluga";
    "Narwhal";
    "Manatee";
    "Dugong";
    "Turtle";
    "Gecko";
    "Iguana";
    "Amber";
    "Coral";
    "Jade";
    "Onyx";
    "Opal";
    "Pearl";
    "Quartz";
    "Topaz";
    "Garnet";
    "Beryl";
    "Agate";
    "Basalt";
    "Granite";
    "Marble";
    "Slate";
    "Flint";
    "Cobalt";
    "Copper";
    "Silver";
    "Bronze";
    "Nickel";
    "Indigo";
    "Violet";
    "Crimson";
    "Scarlet";
    "Maroon";
    "Sienna";
    "Umber";
    "Sable";
    "Ivory";
    "Ebony";
    "Saffron";
    "Sage";
    "Thyme";
    "Basil";
    "Clover";
    "Fennel";
    "Sorrel";
    "Tansy";
    "Yarrow";
    "Aster";
    "Dahlia";
    "Iris";
    "Lily";
    "Lotus";
    "Orchid";
    "Peony";
    "Poppy";
    "Tulip";
    "Zinnia";
  |]

let word_count = Array.length words

type tracked = {
  hashes : string array;
  texts : string array;
  anchors : string array;
  used : (string, unit) Hashtbl.t;  (** File-scoped allocated anchor words. *)
  mutable stamp : int;  (** LRU recency. *)
}

(* A render epoch: one in-order observation of a file from its first line,
   driven by the per-line queries of an anchored read render. The epoch is
   committed lazily, when the next out-of-sequence event flushes it. *)
type epoch = {
  e_key : string;
  e_used : (string, unit) Hashtbl.t;
  old : tracked option;  (** Tracked state snapshot at epoch start. *)
  queues : (string, int Queue.t) Hashtbl.t;
      (** Old line positions by content hash, ascending. *)
  mutable next : int;  (** Next expected one-based line number. *)
  mutable cursor : int;  (** Zero-based match cursor into [old]. *)
  mutable acc_hashes : string list;  (** Observed hashes, reversed. *)
  mutable acc_texts : string list;
  mutable acc_anchors : string list;
  mutable overflow : bool;  (** The observation passed the line cap. *)
}

type t = {
  seed : string;
  max_files : int;
  max_lines : int;
  files : (string, tracked) Hashtbl.t;
  mutable counter : int;  (** Deterministic allocation counter. *)
  mutable clock : int;  (** LRU clock. *)
  mutable epoch : epoch option;
}

let create ?(max_files = default_max_files) ?(max_lines = default_max_lines)
    ~seed () =
  if max_files <= 0 then
    invalid_arg "Spice_tools.Anchor_tracker.create: max_files must be positive";
  if max_lines <= 0 then
    invalid_arg "Spice_tools.Anchor_tracker.create: max_lines must be positive";
  {
    seed;
    max_files;
    max_lines;
    files = Hashtbl.create 64;
    counter = 0;
    clock = 0;
    epoch = None;
  }

let key path = Spice_path.Abs.to_string (W.Path.abs path)
let line_hash text = Spice_digest.key ~length:16 [ text ]

(* Deterministic word allocation: pair indexes derive from the seed and a
   monotone counter. After repeated collisions against a file's used set the
   allocator widens from word pairs to word triples as a last-resort fallback. *)
let fresh_word t ~used =
  let rec loop misses =
    let n = t.counter in
    t.counter <- t.counter + 1;
    let h =
      Spice_digest.to_raw_string
        (Spice_digest.string (t.seed ^ "\x00" ^ string_of_int n))
    in
    let index k =
      (* The two bytes form a 16-bit value first, then reduce mod [word_count];
         [lor] and [mod] share precedence, so bind the pair to keep the reading
         unambiguous. *)
      let pair = (Char.code h.[2 * k] lsl 8) lor Char.code h.[(2 * k) + 1] in
      pair mod word_count
    in
    let word =
      if misses < 64 then words.(index 0) ^ words.(index 1)
      else words.(index 0) ^ words.(index 1) ^ words.(index 2)
    in
    if Hashtbl.mem used word then loop (misses + 1)
    else begin
      Hashtbl.replace used word ();
      word
    end
  in
  loop 0

let touch t doc =
  t.clock <- t.clock + 1;
  doc.stamp <- t.clock

let evict_to_capacity t =
  while Hashtbl.length t.files >= t.max_files do
    let oldest =
      Hashtbl.fold
        (fun key doc oldest ->
          match oldest with
          | Some (_, stamp) when stamp <= doc.stamp -> oldest
          | Some _ | None -> Some (key, doc.stamp))
        t.files None
    in
    match oldest with None -> () | Some (key, _) -> Hashtbl.remove t.files key
  done

let install t key doc =
  if not (Hashtbl.mem t.files key) then evict_to_capacity t;
  Hashtbl.replace t.files key doc;
  touch t doc

(* Position queues for greedy hash matching: for each old content hash, the
   ascending positions where it occurs. Matching consumes the smallest
   position at or past the cursor, so unchanged lines keep their anchors
   while moved-earlier duplicates fall back to fresh words. *)
let position_queues hashes =
  let queues = Hashtbl.create (Array.length hashes) in
  Array.iteri
    (fun i hash ->
      let queue =
        match Hashtbl.find_opt queues hash with
        | Some queue -> queue
        | None ->
            let queue = Queue.create () in
            Hashtbl.replace queues hash queue;
            queue
      in
      Queue.add i queue)
    hashes;
  queues

let pop_match queues ~cursor hash =
  match Hashtbl.find_opt queues hash with
  | None -> None
  | Some queue ->
      let rec loop () =
        match Queue.peek_opt queue with
        | None -> None
        | Some position when position < cursor ->
            ignore (Queue.pop queue);
            loop ()
        | Some position ->
            ignore (Queue.pop queue);
            Some position
      in
      loop ()

let flush_epoch t =
  match t.epoch with
  | None -> ()
  | Some epoch ->
      t.epoch <- None;
      if epoch.overflow then Hashtbl.remove t.files epoch.e_key
      else begin
        let doc =
          {
            hashes = Array.of_list (List.rev epoch.acc_hashes);
            texts = Array.of_list (List.rev epoch.acc_texts);
            anchors = Array.of_list (List.rev epoch.acc_anchors);
            used = epoch.e_used;
            stamp = 0;
          }
        in
        install t epoch.e_key doc
      end

let start_epoch t key =
  flush_epoch t;
  let old = Hashtbl.find_opt t.files key in
  let e_used =
    match old with
    | None -> Hashtbl.create 64
    | Some doc -> Hashtbl.copy doc.used
  in
  let queues =
    match old with
    | None -> Hashtbl.create 0
    | Some doc -> position_queues doc.hashes
  in
  let epoch =
    {
      e_key = key;
      e_used;
      old;
      queues;
      next = 1;
      cursor = 0;
      acc_hashes = [];
      acc_texts = [];
      acc_anchors = [];
      overflow = false;
    }
  in
  t.epoch <- Some epoch;
  epoch

let epoch_line t epoch text =
  let hash = line_hash text in
  let anchor =
    match pop_match epoch.queues ~cursor:epoch.cursor hash with
    | Some position ->
        epoch.cursor <- position + 1;
        (Option.get epoch.old).anchors.(position)
    | None -> fresh_word t ~used:epoch.e_used
  in
  epoch.acc_hashes <- hash :: epoch.acc_hashes;
  epoch.acc_texts <- text :: epoch.acc_texts;
  epoch.acc_anchors <- anchor :: epoch.acc_anchors;
  epoch.next <- epoch.next + 1;
  anchor

let lookup t key number text =
  match Hashtbl.find_opt t.files key with
  | Some doc
    when number >= 1
         && number <= Array.length doc.texts
         && String.equal doc.texts.(number - 1) text ->
      Some doc.anchors.(number - 1)
  | Some _ | None -> None

let source_line t ~path ~number ~text =
  let key = key path in
  let anchor =
    if number = 1 then
      let epoch = start_epoch t key in
      Some (epoch_line t epoch text)
    else
      match t.epoch with
      | Some epoch when String.equal epoch.e_key key && number = epoch.next ->
          if number > t.max_lines then begin
            epoch.overflow <- true;
            None
          end
          else Some (epoch_line t epoch text)
      | Some _ | None ->
          flush_epoch t;
          lookup t key number text
  in
  Option.map Anchor.of_string anchor

let reconcile t ~path ~lines =
  flush_epoch t;
  let key = key path in
  if List.length lines > t.max_lines then Hashtbl.remove t.files key
  else
    let texts = Array.of_list lines in
    let hashes = Array.map line_hash texts in
    match Hashtbl.find_opt t.files key with
    | Some doc when Array.equal String.equal doc.hashes hashes -> touch t doc
    | (Some _ | None) as old ->
        let used =
          match old with
          | None -> Hashtbl.create 64
          | Some doc -> Hashtbl.copy doc.used
        in
        let anchors =
          match old with
          | None -> Array.map (fun _ -> fresh_word t ~used) texts
          | Some doc ->
              let queues = position_queues doc.hashes in
              let cursor = ref 0 in
              Array.map
                (fun hash ->
                  match pop_match queues ~cursor:!cursor hash with
                  | Some position ->
                      cursor := position + 1;
                      doc.anchors.(position)
                  | None -> fresh_word t ~used)
                hashes
        in
        install t key { hashes; texts; anchors; used; stamp = 0 }

let resolve t ~path ~anchor ~expected =
  flush_epoch t;
  let key = key path in
  let not_found = Anchor.Resolver.Not_found { anchor } in
  match Hashtbl.find_opt t.files key with
  | None -> Error not_found
  | Some doc -> (
      touch t doc;
      match
        Array.find_index
          (fun candidate -> String.equal candidate anchor)
          doc.anchors
      with
      | None -> Error not_found
      | Some i ->
          if String.equal doc.texts.(i) expected then Ok (i + 1)
          else
            Error
              (Anchor.Resolver.Mismatch
                 { anchor; expected = doc.texts.(i); provided = expected }))

let resolver t =
  {
    Anchor.Resolver.reconcile = (fun ~path ~lines -> reconcile t ~path ~lines);
    resolve = (fun ~path ~anchor ~expected -> resolve t ~path ~anchor ~expected);
    source =
      Anchor.Source.make (fun ~path ~number ~text ->
          source_line t ~path ~number ~text);
  }
