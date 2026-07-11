#if !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <math.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach_time.h>
#include <pthread.h>

static pthread_once_t monotonic_clock_once = PTHREAD_ONCE_INIT;
static double monotonic_seconds_per_tick = INFINITY;

static void initialize_monotonic_clock(void) {
  mach_timebase_info_data_t info;
  if (mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
    monotonic_seconds_per_tick =
        ((double)info.numer / (double)info.denom) / 1000000000.0;
}
#endif

CAMLprim double spice_fswatch_monotonic_seconds(value unit) {
  (void)unit;
#if defined(__APPLE__)
  if (pthread_once(&monotonic_clock_once, initialize_monotonic_clock) != 0)
    return INFINITY;
  return (double)mach_continuous_time() * monotonic_seconds_per_tick;
#else
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    return INFINITY;
  return (double)now.tv_sec + ((double)now.tv_nsec / 1000000000.0);
#endif
}

CAMLprim value spice_fswatch_monotonic_seconds_bytecode(value unit) {
  CAMLparam1(unit);
  CAMLreturn(caml_copy_double(spice_fswatch_monotonic_seconds(unit)));
}
