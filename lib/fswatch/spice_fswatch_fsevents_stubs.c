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

typedef struct spice_fsevents_t {
  value callback;
  FSEventStreamRef stream;
  dispatch_queue_t queue;
  bool stopped;
} spice_fsevents_t;

#define Fsevents_val(v) (*((spice_fsevents_t **)Data_custom_val(v)))

static void stop_fsevents(spice_fsevents_t *t) {
  if (t == NULL || t->stopped)
    return;
  t->stopped = true;
  if (t->stream != NULL) {
    FSEventStreamStop(t->stream);
    FSEventStreamInvalidate(t->stream);
    FSEventStreamRelease(t->stream);
    t->stream = NULL;
  }
  if (t->queue != NULL) {
    dispatch_release(t->queue);
    t->queue = NULL;
  }
}

static void finalize_fsevents(value v_t) {
  spice_fsevents_t *t = Fsevents_val(v_t);
  if (t != NULL) {
    stop_fsevents(t);
    caml_remove_global_root(&t->callback);
    caml_stat_free(t);
  }
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

  if (t == NULL || t->stopped)
    return;

  for (size_t i = 0; i < numEvents; i++) {
    if (interesting_flags(eventFlags[i])) {
      interesting = true;
      break;
    }
  }

  if (!interesting)
    return;

  caml_c_thread_register();
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
  t->callback = v_callback;
  t->stream = NULL;
  t->queue = NULL;
  t->stopped = false;
  caml_register_global_root(&t->callback);

  CFStringRef path =
      CFStringCreateWithCString(NULL, String_val(v_path), kCFStringEncodingUTF8);
  CFArrayRef paths = CFArrayCreate(NULL, (const void **)&path, 1,
                                   &kCFTypeArrayCallBacks);
  CFRelease(path);

  FSEventStreamContext context = {0, t, NULL, NULL, NULL};
  FSEventStreamCreateFlags flags =
      kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes |
      kFSEventStreamCreateFlagFileEvents;
  t->stream = FSEventStreamCreate(
      NULL, (FSEventStreamCallback)&fsevents_callback, &context, paths,
      kFSEventStreamEventIdSinceNow, Double_val(v_latency), flags);
  CFRelease(paths);
  if (t->stream == NULL) {
    caml_remove_global_root(&t->callback);
    caml_stat_free(t);
    caml_failwith("FSEventStreamCreate failed");
  }

  t->queue = dispatch_queue_create("spice.file_watcher.fsevents", NULL);
  FSEventStreamSetDispatchQueue(t->stream, t->queue);
  if (!FSEventStreamStart(t->stream)) {
    stop_fsevents(t);
    caml_remove_global_root(&t->callback);
    caml_stat_free(t);
    caml_failwith("FSEventStreamStart failed");
  }

  v_t = caml_alloc_custom(&fsevents_ops, sizeof(spice_fsevents_t *), 0, 1);
  Fsevents_val(v_t) = t;
  CAMLreturn(v_t);
}

CAMLprim value spice_file_watcher_fsevents_stop(value v_t) {
  CAMLparam1(v_t);
  stop_fsevents(Fsevents_val(v_t));
  CAMLreturn(Val_unit);
}

#else

CAMLprim value spice_file_watcher_fsevents_available(value unit) {
  (void)unit;
  return Val_false;
}

CAMLprim value spice_file_watcher_fsevents_create(value v_path, value v_latency,
                                                  value v_callback) {
  (void)v_path;
  (void)v_latency;
  (void)v_callback;
  caml_failwith("fsevents is only available on macos");
}

CAMLprim value spice_file_watcher_fsevents_stop(value v_t) {
  (void)v_t;
  caml_failwith("fsevents is only available on macos");
}

#endif
