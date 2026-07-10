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
#include <poll.h>
#include <sys/eventfd.h>
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
  CAMLlocal1(result);
  int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
  if (fd == -1)
    uerror("inotify_init1", Nothing);

  int wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (wake_fd == -1) {
    int error = errno;
    close(fd);
    errno = error;
    uerror("eventfd", Nothing);
  }

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(fd));
  Store_field(result, 1, Val_int(wake_fd));
  CAMLreturn(result);
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

CAMLprim value spice_file_watcher_inotify_wake(value fd) {
  CAMLparam1(fd);
  uint64_t increment = 1;

  for (;;) {
    ssize_t length = write(Int_val(fd), &increment, sizeof(increment));
    if (length == (ssize_t)sizeof(increment))
      CAMLreturn(Val_unit);
    if (length == -1 && errno == EINTR)
      continue;
    if (length == -1 && errno == EAGAIN)
      CAMLreturn(Val_unit);
    if (length == -1)
      uerror("eventfd write", Nothing);
    errno = EIO;
    uerror("eventfd write", Nothing);
  }
}

CAMLprim value spice_file_watcher_inotify_read(value fd, value wake_fd) {
  CAMLparam2(fd, wake_fd);
  int c_fd = Int_val(fd);
  int c_wake_fd = Int_val(wake_fd);
  char buffer[65536] __attribute__((aligned(__alignof__(struct inotify_event))));

  for (;;) {
    struct pollfd poll_fds[2] = {
        {.fd = c_wake_fd, .events = POLLIN},
        {.fd = c_fd, .events = POLLIN},
    };
    ssize_t length = -1;
    int error = 0;
    int stopped = 0;

    caml_release_runtime_system();

    for (;;) {
      int ready = poll(poll_fds, 2, -1);
      if (ready == -1 && errno == EINTR)
        continue;
      if (ready == -1) {
        error = errno;
        break;
      }

      /* Stop wins when both descriptors are ready: no notification may keep
         the owner from joining a reader after shutdown was requested. */
      if (poll_fds[0].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) {
        uint64_t counter;
        while (read(c_wake_fd, &counter, sizeof(counter)) == -1 &&
               errno == EINTR) {
        }
        stopped = 1;
        break;
      }

      if (poll_fds[1].revents & POLLIN) {
        length = read(c_fd, buffer, sizeof(buffer));
        if (length == -1 && errno == EINTR)
          continue;
        if (length == -1 && errno == EAGAIN)
          continue;
        if (length == -1) {
          error = errno;
          break;
        }
        if (length == 0) {
          error = EIO;
          break;
        }
        break;
      }

      if (poll_fds[1].revents & POLLNVAL) {
        error = EBADF;
        break;
      }
      if (poll_fds[1].revents & (POLLERR | POLLHUP)) {
        error = EIO;
        break;
      }
    }

    caml_acquire_runtime_system();

    if (error != 0) {
      errno = error;
      uerror("read", Nothing);
    }
    if (stopped)
      CAMLreturn(Val_false);

    for (char *ptr = buffer; ptr < buffer + length;) {
      const struct inotify_event *event = (const struct inotify_event *)ptr;
      if (event_is_interesting(event))
        CAMLreturn(Val_true);
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

CAMLprim value spice_file_watcher_inotify_wake(value fd) {
  (void)fd;
  unix_error(ENOTSUP, "eventfd write", Nothing);
}

CAMLprim value spice_file_watcher_inotify_read(value fd, value wake_fd) {
  (void)fd;
  (void)wake_fd;
  unix_error(ENOTSUP, "poll", Nothing);
}

#endif
