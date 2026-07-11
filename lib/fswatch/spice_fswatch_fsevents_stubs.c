#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>

#if defined(__APPLE__)
#include <AvailabilityMacros.h>
#endif

#if defined(__APPLE__) && MAC_OS_X_VERSION_MIN_REQUIRED >= 101000

#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdatomic.h>

#ifndef kFSEventStreamEventFlagMustScanSubDirs
#define kFSEventStreamEventFlagMustScanSubDirs 0x00000001
#endif

#ifndef kFSEventStreamEventFlagItemCreated
#define kFSEventStreamEventFlagItemCreated 0
#endif
#ifndef kFSEventStreamEventFlagItemRemoved
#define kFSEventStreamEventFlagItemRemoved 0
#endif
#ifndef kFSEventStreamEventFlagItemRenamed
#define kFSEventStreamEventFlagItemRenamed 0
#endif
#ifndef kFSEventStreamEventFlagItemModified
#define kFSEventStreamEventFlagItemModified 0
#endif
#ifndef kFSEventStreamEventFlagItemInodeMetaMod
#define kFSEventStreamEventFlagItemInodeMetaMod 0
#endif
#ifndef kFSEventStreamEventFlagItemChangeOwner
#define kFSEventStreamEventFlagItemChangeOwner 0
#endif
#ifndef kFSEventStreamEventFlagItemXattrMod
#define kFSEventStreamEventFlagItemXattrMod 0
#endif
#ifndef kFSEventStreamCreateFlagFileEvents
#define kFSEventStreamCreateFlagFileEvents 0
#endif

typedef enum spice_fsevents_state {
  SPICE_FSEVENTS_ACTIVE,
  SPICE_FSEVENTS_STOPPING,
  SPICE_FSEVENTS_DRAINED,
} spice_fsevents_state;

typedef struct spice_fsevents_t {
  value callback;
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  dispatch_group_t drain_group;
  atomic_int state;
} spice_fsevents_t;

typedef _Atomic(spice_fsevents_t *) spice_fsevents_handle;

#define Fsevents_handle(v) ((spice_fsevents_handle *)Data_custom_val(v))

static spice_fsevents_t *take_fsevents(value v_t) {
  return atomic_exchange_explicit(Fsevents_handle(v_t), NULL,
                                  memory_order_acq_rel);
}

static void drain_queue(void *unused) { (void)unused; }

static void stop_fsevents(spice_fsevents_t *t) {
  if (t->stream != NULL) {
    FSEventStreamStop(t->stream);
    FSEventStreamInvalidate(t->stream);
    dispatch_sync_f(t->queue, NULL, drain_queue);
    FSEventStreamRelease(t->stream);
    t->stream = NULL;
  }
  if (t->queue != NULL) {
    dispatch_release(t->queue);
    t->queue = NULL;
  }
}

static dispatch_queue_t cleanup_queue(void) {
  return dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
}

static void drain_fsevents(void *context) {
  spice_fsevents_t *t = context;
  stop_fsevents(t);
  atomic_store_explicit(&t->state, SPICE_FSEVENTS_DRAINED,
                        memory_order_release);
}

static void free_drained_fsevents(void *context) {
  spice_fsevents_t *t = context;
  if (!caml_c_thread_register()) {
    /* Domain zero can be unavailable during process shutdown. Native state is
       already drained; keep the root and its address alive until process exit. */
    return;
  }
  caml_acquire_runtime_system();
  caml_remove_generational_global_root(&t->callback);
  caml_release_runtime_system();
  caml_c_thread_unregister();
  dispatch_release(t->drain_group);
  caml_stat_free(t);
}

static void finalize_fsevents(value v_t) {
  spice_fsevents_t *t = take_fsevents(v_t);
  if (t == NULL)
    return;

  int expected = SPICE_FSEVENTS_ACTIVE;
  if (atomic_compare_exchange_strong_explicit(
          &t->state, &expected, SPICE_FSEVENTS_STOPPING,
          memory_order_acq_rel, memory_order_acquire))
    dispatch_group_async_f(t->drain_group, cleanup_queue(), t,
                           drain_fsevents);

  if (expected == SPICE_FSEVENTS_DRAINED)
    dispatch_async_f(cleanup_queue(), t, free_drained_fsevents);
  else
    dispatch_group_notify_f(t->drain_group, cleanup_queue(), t,
                            free_drained_fsevents);
}

static struct custom_operations fsevents_ops = {
    "spice.file_watcher.fsevents", finalize_fsevents, custom_compare_default,
    custom_hash_default,           custom_serialize_default,
    custom_deserialize_default,    custom_compare_ext_default,
    custom_fixed_length_default};

static bool interesting_flags(FSEventStreamEventFlags flags) {
  return flags & (kFSEventStreamEventFlagMustScanSubDirs |
                  kFSEventStreamEventFlagUserDropped |
                  kFSEventStreamEventFlagKernelDropped |
                  kFSEventStreamEventFlagEventIdsWrapped |
                  kFSEventStreamEventFlagRootChanged |
                  kFSEventStreamEventFlagItemCreated |
                  kFSEventStreamEventFlagItemRemoved |
                  kFSEventStreamEventFlagItemRenamed |
                  kFSEventStreamEventFlagItemModified |
                  kFSEventStreamEventFlagItemInodeMetaMod |
                  kFSEventStreamEventFlagItemChangeOwner |
                  kFSEventStreamEventFlagItemXattrMod);
}

static void fsevents_callback(const FSEventStreamRef streamRef, void *client,
                              size_t numEvents, void *eventPaths,
                              const FSEventStreamEventFlags eventFlags[],
                              const FSEventStreamEventId eventIds[]) {
  (void)streamRef;
  (void)eventPaths;
  (void)eventIds;
  spice_fsevents_t *t = (spice_fsevents_t *)client;
  bool interesting = false;

  if (t == NULL ||
      atomic_load_explicit(&t->state, memory_order_acquire) !=
          SPICE_FSEVENTS_ACTIVE)
    return;

  for (size_t i = 0; i < numEvents; i++) {
    if (interesting_flags(eventFlags[i])) {
      interesting = true;
      break;
    }
  }

  if (!interesting)
    return;

  if (!caml_c_thread_register())
    return;
  caml_acquire_runtime_system();
  CAMLparam0();
  CAMLlocal1(result);
  result = caml_callback_exn(t->callback, Val_unit);
  (void)result;
  CAMLdrop;
  caml_release_runtime_system();
  caml_c_thread_unregister();
}

CAMLprim value spice_file_watcher_fsevents_available(value unit) {
  (void)unit;
  return Val_true;
}

CAMLprim value spice_file_watcher_fsevents_create(value v_path, value v_latency,
                                                  value v_callback) {
  CAMLparam3(v_path, v_latency, v_callback);
  CAMLlocal1(v_t);

  spice_fsevents_t *t = caml_stat_alloc(sizeof(spice_fsevents_t));
  t->callback = Val_unit;
  t->stream = NULL;
  t->queue = NULL;
  t->drain_group = dispatch_group_create();
  if (t->drain_group == NULL) {
    caml_stat_free(t);
    caml_failwith("dispatch_group_create failed");
  }
  atomic_init(&t->state, SPICE_FSEVENTS_ACTIVE);

  CFStringRef path =
      CFStringCreateWithCString(NULL, String_val(v_path), kCFStringEncodingUTF8);
  if (path == NULL) {
    dispatch_release(t->drain_group);
    caml_stat_free(t);
    caml_failwith("FSEvents path is not valid UTF-8");
  }

  CFArrayRef paths = CFArrayCreate(NULL, (const void **)&path, 1,
                                   &kCFTypeArrayCallBacks);
  CFRelease(path);
  if (paths == NULL) {
    dispatch_release(t->drain_group);
    caml_stat_free(t);
    caml_failwith("CFArrayCreate failed");
  }

  FSEventStreamContext context = {0, t, NULL, NULL, NULL};
  FSEventStreamCreateFlags flags =
      kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes |
      kFSEventStreamCreateFlagFileEvents;
  t->stream = FSEventStreamCreate(
      NULL, (FSEventStreamCallback)&fsevents_callback, &context, paths,
      kFSEventStreamEventIdSinceNow, Double_val(v_latency), flags);
  CFRelease(paths);
  if (t->stream == NULL) {
    dispatch_release(t->drain_group);
    caml_stat_free(t);
    caml_failwith("FSEventStreamCreate failed");
  }

  t->queue = dispatch_queue_create("spice.file_watcher.fsevents", NULL);
  if (t->queue == NULL) {
    FSEventStreamRelease(t->stream);
    dispatch_release(t->drain_group);
    caml_stat_free(t);
    caml_failwith("dispatch_queue_create failed");
  }

  v_t = caml_alloc_custom(&fsevents_ops, sizeof(spice_fsevents_handle), 0, 1);
  atomic_init(Fsevents_handle(v_t), NULL);
  t->callback = v_callback;
  caml_register_generational_global_root(&t->callback);
  FSEventStreamSetDispatchQueue(t->stream, t->queue);
  if (!FSEventStreamStart(t->stream)) {
    FSEventStreamInvalidate(t->stream);
    FSEventStreamRelease(t->stream);
    dispatch_release(t->queue);
    caml_remove_generational_global_root(&t->callback);
    dispatch_release(t->drain_group);
    caml_stat_free(t);
    caml_failwith("FSEventStreamStart failed");
  }

  atomic_store_explicit(Fsevents_handle(v_t), t, memory_order_release);
  CAMLreturn(v_t);
}

CAMLprim value spice_file_watcher_fsevents_stop(value v_t) {
  CAMLparam1(v_t);
  spice_fsevents_t *t =
      atomic_load_explicit(Fsevents_handle(v_t), memory_order_acquire);
  if (t == NULL)
    CAMLreturn(Val_unit);

  int expected = SPICE_FSEVENTS_ACTIVE;
  if (atomic_compare_exchange_strong_explicit(
          &t->state, &expected, SPICE_FSEVENTS_STOPPING,
          memory_order_acq_rel, memory_order_acquire)) {
    dispatch_group_async_f(t->drain_group, cleanup_queue(), t,
                           drain_fsevents);
    caml_release_runtime_system();
    dispatch_group_wait(t->drain_group, DISPATCH_TIME_FOREVER);
    caml_acquire_runtime_system();
  } else if (expected == SPICE_FSEVENTS_STOPPING) {
    CAMLreturn(Val_unit);
  }

  spice_fsevents_t *owned = t;
  if (atomic_compare_exchange_strong_explicit(
          Fsevents_handle(v_t), &owned, NULL, memory_order_acq_rel,
          memory_order_acquire)) {
    caml_remove_generational_global_root(&t->callback);
    dispatch_release(t->drain_group);
    caml_stat_free(t);
  }
  CAMLreturn(Val_unit);
}

#else

CAMLprim value spice_file_watcher_fsevents_available(value unit) {
  (void)unit;
  return Val_false;
}

CAMLprim value spice_file_watcher_fsevents_create(value v_path, value v_latency,
                                                  value v_callback) {
  CAMLparam3(v_path, v_latency, v_callback);
  caml_failwith("fsevents is only available on macos");
}

CAMLprim value spice_file_watcher_fsevents_stop(value v_t) {
  CAMLparam1(v_t);
  caml_failwith("fsevents is only available on macos");
}

#endif
