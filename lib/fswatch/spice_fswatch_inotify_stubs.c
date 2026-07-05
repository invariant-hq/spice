#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>

#if defined(__linux__)
#include <limits.h>
#include <sys/inotify.h>
#include <unistd.h>

#ifndef IN_CLOEXEC
#define IN_CLOEXEC 02000000
#endif

#ifndef IN_ONLYDIR
#define IN_ONLYDIR 0
#endif

#ifndef IN_EXCL_UNLINK
#define IN_EXCL_UNLINK 0
#endif

CAMLprim value spice_file_watcher_inotify_supported(value unit) {
  (void)unit;
  return Val_true;
}

CAMLprim value spice_file_watcher_inotify_create(value unit) {
  CAMLparam1(unit);
  int fd = inotify_init1(IN_CLOEXEC);
  if (fd == -1)
    uerror("inotify_init1", Nothing);
  CAMLreturn(Val_int(fd));
}

CAMLprim value spice_file_watcher_inotify_add_watch(value fd, value path) {
  CAMLparam2(fd, path);
  int mask = IN_ONLYDIR | IN_EXCL_UNLINK | IN_ATTRIB | IN_CREATE | IN_DELETE |
             IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO |
             IN_MOVE_SELF | IN_DELETE_SELF | IN_UNMOUNT;
  int watch = inotify_add_watch(Int_val(fd), String_val(path), mask);
  if (watch == -1)
    uerror("inotify_add_watch", path);
  CAMLreturn(Val_int(watch));
}

CAMLprim value spice_file_watcher_inotify_rm_watch(value fd, value watch) {
  CAMLparam2(fd, watch);
  if (inotify_rm_watch(Int_val(fd), Int_val(watch)) == -1 && errno != EINVAL &&
      errno != EBADF)
    uerror("inotify_rm_watch", Nothing);
  CAMLreturn(Val_unit);
}

static int event_is_interesting(const struct inotify_event *event) {
  uint32_t mask = event->mask;
  return mask & (IN_Q_OVERFLOW | IN_ATTRIB | IN_CREATE | IN_DELETE |
                 IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO |
                 IN_MOVE_SELF | IN_DELETE_SELF | IN_UNMOUNT);
}

CAMLprim value spice_file_watcher_inotify_read(value fd) {
  CAMLparam1(fd);
  char buffer[65536] __attribute__((aligned(__alignof__(struct inotify_event))));
  ssize_t length;

  for (;;) {
    caml_release_runtime_system();
    length = read(Int_val(fd), buffer, sizeof(buffer));
    caml_acquire_runtime_system();

    if (length == -1 && errno == EINTR)
      continue;
    if (length == -1)
      uerror("read", Nothing);
    if (length <= 0)
      continue;

    for (char *ptr = buffer; ptr < buffer + length;) {
      const struct inotify_event *event = (const struct inotify_event *)ptr;
      if (event_is_interesting(event))
        CAMLreturn(Val_unit);
      ptr += sizeof(struct inotify_event) + event->len;
    }
  }
}

#else

CAMLprim value spice_file_watcher_inotify_supported(value unit) {
  (void)unit;
  return Val_false;
}

CAMLprim value spice_file_watcher_inotify_create(value unit) {
  (void)unit;
  unix_error(ENOTSUP, "inotify_init1", Nothing);
}

CAMLprim value spice_file_watcher_inotify_add_watch(value fd, value path) {
  (void)fd;
  (void)path;
  unix_error(ENOTSUP, "inotify_add_watch", Nothing);
}

CAMLprim value spice_file_watcher_inotify_rm_watch(value fd, value watch) {
  (void)fd;
  (void)watch;
  unix_error(ENOTSUP, "inotify_rm_watch", Nothing);
}

CAMLprim value spice_file_watcher_inotify_read(value fd) {
  (void)fd;
  unix_error(ENOTSUP, "read", Nothing);
}

#endif
