/*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*/

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>

#ifdef __APPLE__
#include <stdint.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

/* Reads an integer sysctl by name; -1 when the sysctl does not exist or on
   non-macOS systems. Values narrower than 64 bits are zero-extended (the
   buffer is zero-initialized and macOS is little-endian). */
CAMLprim value spice_modelfit_sysctl_u64(value name)
{
  CAMLparam1(name);
#ifdef __APPLE__
  uint64_t result = 0;
  size_t len = sizeof(result);
  if (sysctlbyname(String_val(name), &result, &len, NULL, 0) != 0)
    CAMLreturn(caml_copy_int64(-1));
  CAMLreturn(caml_copy_int64((int64_t)result));
#else
  (void)name;
  CAMLreturn(caml_copy_int64(-1));
#endif
}
