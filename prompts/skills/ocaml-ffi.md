---
description: Guides writing correct and performant OCaml-to-C FFI stubs without ctypes. Use when writing C bindings, wrapping a C library, writing or reviewing stubs and externals, or touching any C file that includes caml/ headers. Triggers on phrases like "C binding", "FFI", "external", "stub", "noalloc", "bigarray interop", "custom block", "caml_release_runtime", or "wrap this C library".
---

# OCaml FFI to C Without Ctypes

A C stub is a translation layer: decode OCaml values, call C, encode
the result, return. Correctness depends on respecting the OCaml
runtime's GC and concurrency invariants. Get the invariants right
first; optimize second.

## 1. Understand What You Are Wrapping

Before writing any C, answer these questions from the OCaml side:

### What does the caller's code look like?

Write the OCaml API the user will call. This determines the stub
shape, not the other way around.

```ocaml
(* The user wants this: *)
val compress : string -> string
val compress_into : buf -> src:string -> int

(* NOT this: *)
val compress_raw : nativeint -> nativeint -> int -> int -> int
```

The C side serves the OCaml API, not vice versa.

### What are the ownership and lifetime rules?

For every resource the C side manages, decide:

- **Who allocates?** (OCaml caller, C stub, or wrapped library)
- **Who frees?** (explicit close, finalizer, or caller)
- **How long is it valid?** (call duration, handle lifetime, forever)

Make ownership explicit in the OCaml type:

```ocaml
type t
val create : unit -> t
val close : t -> unit        (* deterministic cleanup *)
(* finalizer as safety net, not primary mechanism *)
```

### Copy or zero-copy?

| Pattern | When to use |
|---------|-------------|
| Copy in, copy out | Short buffers, syscalls, simple wrappers |
| Bigarray zero-copy | Large numeric buffers, I/O buffers, codecs |
| Custom block handle | Opaque C-owned resources (DB, streams, contexts) |

Decide before writing stubs. Mixing strategies mid-implementation
creates confusion about who owns what.

## 2. GC Invariants (Non-Negotiable)

These rules are law. Violating any one of them causes memory
corruption that may not manifest until much later.

### Root every `value`

Any C function with parameters or locals of type `value` must:

- Begin with `CAMLparam*` (for parameters) and `CAMLlocal*` (for
  local `value` variables).
- Exit only via `CAMLreturn` / `CAMLreturnT`.
- Never keep a `value` variable live across a potential GC point
  without rooting it.

```c
CAMLprim value my_stub(value v1, value v2)
{
  CAMLparam2(v1, v2);
  CAMLlocal1(result);

  /* ... work ... */

  CAMLreturn(result);
}
```

No exceptions. Even "trivial" stubs that "cannot allocate" should
follow this discipline unless you are explicitly using `[@@noalloc]`
(see section 5).

### Never store derived pointers across GC points

A derived pointer is anything computed from an OCaml value:
`String_val(v)`, `Bytes_val(v)`, `Caml_ba_data_val(v)`, `Field(v,i)`.

These pointers become invalid if the GC moves the value. Dereference
immediately and do not store them in variables that survive an
allocation or callback.

```c
/* WRONG: p may be invalidated by caml_alloc_string */
char *p = String_val(v);
value s = caml_alloc_string(len);  /* GC point */
memcpy(Bytes_val(s), p, len);      /* p is dangling */

/* RIGHT: re-derive after allocation */
value s = caml_alloc_string(len);
memcpy(Bytes_val(s), String_val(v), len);
```

### Use `Store_field` for heap writes

Assignments into structured blocks must use `Store_field` (or
`Store_double_field`), never direct pointer assignment. The write
barrier must fire to maintain GC invariants.

The destination argument must itself be a rooted variable to prevent
GC invalidation during evaluation of other arguments.

### No naked pointers (OCaml 5)

Raw C pointers outside the OCaml heap cannot be stored directly as
OCaml values. The multicore GC will treat them as heap pointers and
corrupt memory.

Wrap pointers in custom blocks or abstract blocks (see section 3).

### Global roots for long-lived values

If C code stores an OCaml value outside the OCaml heap (e.g. a
callback closure), register it as a root:

```c
static value callback_fn;

void register_callback(value fn)
{
  callback_fn = fn;
  caml_register_generational_global_root(&callback_fn);
}

void update_callback(value fn)
{
  caml_modify_generational_global_root(&callback_fn, fn);
}

void unregister_callback(void)
{
  caml_remove_generational_global_root(&callback_fn);
}
```

Use generational roots when updates are infrequent (the common case
for callbacks). Use `caml_modify_generational_global_root` for
updates, never direct assignment.

## 3. Representation Choices

### Custom blocks (recommended default for handles)

A custom block wraps a C pointer as an OCaml heap object with a
finalizer and optional comparison/hash/serialization operations.

```c
#include <caml/custom.h>

struct my_handle { /* ... */ };

static void finalize_handle(value v)
{
  struct my_handle *h = *(struct my_handle **) Data_custom_val(v);
  if (h != NULL) {
    my_handle_free(h);
  }
}

static struct custom_operations handle_ops = {
  .identifier  = "my_handle",
  .finalize    = finalize_handle,
  .compare     = custom_compare_default,
  .hash        = custom_hash_default,
  .serialize   = custom_serialize_default,
  .deserialize = custom_deserialize_default,
  .compare_ext = custom_compare_ext_default,
};

static value alloc_handle(struct my_handle *h)
{
  value v = caml_alloc_custom(&handle_ops, sizeof(struct my_handle *), 0, 1);
  *(struct my_handle **) Data_custom_val(v) = h;
  return v;
}
```

Finalizer restrictions (violations are unsafe — the runtime does not
check them):

- No OCaml heap allocation.
- No callbacks into OCaml.
- No `caml_release_runtime_system`.
- Access only `Data_custom_val` and global root removal.

Finalizers are a safety net. Expose explicit `close` on the OCaml
side for deterministic cleanup.

### Abstract blocks

`Abstract_tag` blocks are not traced by the GC. They must not contain
any `value`. Useful for opaque handles when you need a block but no
custom operations.

### Bigarray (primary zero-copy primitive)

Use Bigarray when you need a large buffer shared between OCaml and C
without copying:

```c
#include <caml/bigarray.h>

/* Read directly into caller-provided bigarray */
CAMLprim value stub_read_into(value vbuf, value vlen)
{
  CAMLparam2(vbuf, vlen);
  size_t len = (size_t) Int_val(vlen);

  /* Derive and use immediately; do not store across GC points */
  uint8_t *p = (uint8_t *) Caml_ba_data_val(vbuf);
  size_t nread = do_read(p, len);

  CAMLreturn(Val_int(nread));
}
```

Bigarrays can be `CAML_BA_MANAGED` (OCaml-allocated),
`CAML_BA_EXTERNAL` (C-allocated, user-managed), or
`CAML_BA_MAPPED_FILE`. Wrap an existing C array with
`caml_ba_alloc` / `caml_ba_alloc_dims`.

Use `caml_alloc_custom_mem` when allocating custom blocks with large
out-of-heap memory to pace GC correctly via the `custom_*` ratios.

## 4. The Stub Pattern

A correct stub follows this structure:

1. `CAMLparam*` / `CAMLlocal*` at the top.
2. Decode OCaml arguments into C values.
3. If blocking: copy arguments to C memory, release runtime lock,
   do work, reacquire lock (see section 6).
4. If non-blocking: call the C helper directly.
5. Encode the C result as an OCaml value.
6. `CAMLreturn`.

```c
/* Pure C helper: no OCaml types, no runtime interaction */
static int do_work(const char *input, size_t len, char *output)
{
  /* ... */
  return result_len;
}

/* Thin OCaml wrapper */
CAMLprim value stub_do_work(value vinput)
{
  CAMLparam1(vinput);
  CAMLlocal1(vresult);

  const char *input = String_val(vinput);
  size_t len = caml_string_length(vinput);

  /* Allocate output buffer in C */
  char *output = malloc(len * 2);
  if (output == NULL) caml_raise_out_of_memory();

  int rlen = do_work(input, len, output);

  vresult = caml_alloc_string(rlen);
  memcpy(Bytes_val(vresult), output, rlen);
  free(output);

  CAMLreturn(vresult);
}
```

Keep the C helper pure and the wrapper thin. The helper can be
unit-tested with native C tooling. The wrapper minimizes the surface
where GC rules apply.

One decoding trap: an OCaml string may contain NUL bytes. Before
passing `String_val(v)` to a C API that expects a NUL-terminated
string, check `strlen(String_val(v)) == caml_string_length(v)` and
raise `Invalid_argument` otherwise (the runtime's own unix bindings do
this for paths).

## 5. Performance

### Unboxed externals

Boxing/unboxing floats allocates on every call. Use `[@@unboxed]` to
eliminate this in numeric loops:

```ocaml
external lerp : float -> float -> float -> float
  = "lerp_byte" "lerp_unboxed" [@@unboxed]
```

```c
CAMLprim double lerp_unboxed(double a, double b, double t)
{
  return a + t * (b - a);
}

CAMLprim value lerp_byte(value va, value vb, value vt)
{
  return caml_copy_double(
    lerp_unboxed(Double_val(va), Double_val(vb), Double_val(vt)));
}
```

The bytecode stub is required. The native stub takes and returns raw
C types with no `value` involvement.

### Untagged integers

Use `[@untagged]` on each `int` parameter/result to avoid
tagging/untagging overhead — the attribute attaches per parameter, and
the C side must use `intnat`, never C `int`:

```ocaml
external count_bits : (int [@untagged]) -> (int [@untagged])
  = "count_bits_byte" "count_bits_native" [@@noalloc]
```

```c
CAMLprim intnat count_bits_native(intnat x) { return __builtin_popcountl(x); }
CAMLprim value count_bits_byte(value v) { return Val_int(count_bits_native(Int_val(v))); }
```

`[@untagged]` also works for other immediate types (`bool`, `char`,
constant-constructor variants).

### `[@@noalloc]`

Eliminates the `caml_c_call` indirection, which matters for small
functions called in tight loops. Use it **only** when the C function:

- Does not allocate on the OCaml heap (no `caml_alloc_*`,
  `caml_copy_*`, `caml_alloc_string`, etc.).
- Does not raise exceptions.
- Does not release the domain lock.

```ocaml
external blit_unsafe :
  src:('a, 'b, 'c) Bigarray.Array1.t -> src_off:int ->
  dst:('a, 'b, 'c) Bigarray.Array1.t -> dst_off:int ->
  len:int -> unit
  = "stub_ba_blit" [@@noalloc]
```

If any precondition is violated, behavior is undefined. Do not guess.

### Bigarray zero-copy vs copying

Prefer Bigarray when the buffer is large and accessed repeatedly.
Copy when the buffer is small and short-lived (a pathname, a short
message). The copy cost for small buffers is negligible; the
complexity cost of zero-copy lifetime management is not.

## 6. Concurrency and Multicore (OCaml 5)

### Releasing the domain lock for blocking calls

When a C function blocks (I/O, locks, long computation), release the
runtime lock so other domains and systhreads can run:

```c
CAMLprim value stub_blocking_read(value vpath)
{
  CAMLparam1(vpath);
  CAMLlocal1(vresult);

  /* Copy argument BEFORE releasing lock */
  char *path = caml_stat_strdup(String_val(vpath));

  caml_release_runtime_system();
  int fd = open(path, O_RDONLY);
  /* ... do blocking work ... */
  caml_acquire_runtime_system();

  caml_stat_free(path);

  if (fd < 0) caml_failwith("open failed");

  vresult = Val_int(fd);
  CAMLreturn(vresult);
}
```

While released:

- **No** access to OCaml values.
- **No** calls to runtime functions.
- **No** callbacks into OCaml.

Copy everything you need into C memory before releasing.

Both release and acquire poll pending actions and may run arbitrary
OCaml code — including raising an asynchronous exception. Do not call
them while holding C resources that a raise would leak.

Historical aliases (equivalent):
- `caml_enter_blocking_section` = `caml_release_runtime_system`
- `caml_leave_blocking_section` = `caml_acquire_runtime_system`

### Registering C-created threads

Threads not created by OCaml must register before calling into the
runtime:

```c
void *my_thread_func(void *arg)
{
  caml_c_thread_register();

  /* ... can now acquire runtime and callback into OCaml ... */

  caml_c_thread_unregister();
  return NULL;
}
```

C-registered threads belong to domain 0, and the runtime lock is
*not* held when `caml_c_thread_register` returns. Callbacks must hold
the domain lock. The sequence for a C thread calling back into OCaml:

1. `caml_c_thread_register()` (once per thread lifetime).
2. `caml_acquire_runtime_system()`.
3. Build OCaml arguments, root them.
4. `caml_callback` / `caml_callback_exn`.
5. Copy results to C memory.
6. `caml_release_runtime_system()`.
7. `caml_c_thread_unregister()` (at thread shutdown).

### Pending actions in long-running C loops

If a C function holds the runtime lock for a long time without
allocating, call `caml_process_pending_actions()` at safe points to
avoid starving signal handlers, finalizers, and memprof callbacks.

## 7. Errors and Exceptions

### Raising from C

`caml_failwith`, `caml_invalid_argument`, `caml_raise_*` are
`noreturn`. Control does not return to the C frame. Any C resources
allocated before the raise will leak.

### Safe cleanup before raising

On OCaml 5.3+, use the non-raising exception constructors
(`caml_exception_*` variants of the `caml/fail.h` raisers), clean up,
then raise. On older runtimes these do not exist — restructure so all
cleanup happens before the raising call instead.

```c
CAMLprim value stub_with_cleanup(value varg)
{
  CAMLparam1(varg);

  char *buf = malloc(4096);
  if (buf == NULL) caml_raise_out_of_memory();

  int rc = do_work(buf, String_val(varg));
  if (rc < 0) {
    value exn = caml_exception_failure("do_work failed");
    free(buf);
    caml_raise(exn);
  }

  free(buf);
  CAMLreturn(Val_unit);
}
```

`caml_exception_failure` builds the exception value without raising
it. `caml_raise` propagates after cleanup.

### `caml_result` for structured error paths (OCaml 5.3+)

For complex stubs with multiple error paths, use `caml_result`
(introduced in OCaml 5.3, together with `caml_callback*_res`
variants):

1. Perform work, produce `Result_value(v)` or
   `Result_exception(exn)`.
2. Clean up C resources deterministically.
3. Return with `caml_get_value_or_raise(result)`.

This gives a single exit point consistent with `CAMLreturn` and
handles both success and error cleanup uniformly.

## 8. Build and Test

### Dune integration

Use `foreign_stubs` in your library stanza:

```lisp
(library
 (name mylib)
 (foreign_stubs (language c) (names my_stubs))
 (c_library_flags (-lmyextlib)))
```

### Bytecode + native

Every `[@@unboxed]` or `[@@noalloc]` external needs a bytecode
stub. The native stub uses raw C types; the bytecode stub
decodes/encodes `value` types.

```ocaml
external foo : float -> float
  = "foo_byte" "foo_native" [@@unboxed] [@@noalloc]
```

### Test stubs as untrusted code

- **AddressSanitizer (ASan)**: detects out-of-bounds, use-after-free.
- **UndefinedBehaviorSanitizer (UBSan)**: detects misaligned access,
  signed overflow.
- **ThreadSanitizer (TSan)**: available in OCaml 5.2+, detects data
  races in mixed OCaml/C code.
- **Valgrind**: detects memory errors and undefined-value usage.
- **AFL instrumentation** (`-afl-instrument`): fuzz OCaml programs
  including their C stubs.

Run sanitizers in CI, not just locally.

## Checklist

- [ ] OCaml API designed first; stubs serve the OCaml interface, not
      the C API shape
- [ ] Ownership and lifetimes explicit: who allocates, who frees,
      how long is it valid
- [ ] Every stub with `value` params/locals uses `CAMLparam*` /
      `CAMLlocal*` / `CAMLreturn*` on all exit paths
- [ ] No derived pointers (`String_val`, `Caml_ba_data_val`, `Field`)
      stored across GC points
- [ ] Heap writes use `Store_field` / `caml_modify` /
      `caml_initialize`; destination is rooted
- [ ] No naked pointers; C handles wrapped in custom or abstract
      blocks
- [ ] Global OCaml values registered as roots; updates via
      `caml_modify_generational_global_root`
- [ ] `[@@noalloc]` used only when the function truly does not
      allocate, raise, or release the domain lock
- [ ] Blocking calls: arguments copied to C memory before
      `caml_release_runtime_system`; no OCaml access while released
- [ ] C-created threads registered before callbacks; callbacks hold
      the domain lock
- [ ] Exceptions: cleanup performed before raising; `caml_exception_*`
      used for non-raising construction when cleanup is needed
- [ ] Custom block finalizers do only minimal work: no heap
      allocation, no callbacks, no runtime release
- [ ] Bytecode stubs provided for all `[@@unboxed]` /
      `[@@noalloc]` externals
- [ ] Sanitizers (ASan, UBSan, TSan) run in CI
- [ ] No reliance on undocumented runtime internals (`CAML_INTERNALS`)
