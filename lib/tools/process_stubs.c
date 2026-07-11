#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>

#if !defined(_WIN32)
#include <unistd.h>
#endif

CAMLprim value caml_spice_tools_fchdir(value fd) {
  CAMLparam1(fd);
#if defined(_WIN32)
  unix_error(ENOSYS, "fchdir", Nothing);
#else
  if (fchdir(Int_val(fd)) == -1)
    uerror("fchdir", Nothing);
#endif
  CAMLreturn(Val_unit);
}
