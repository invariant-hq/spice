#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <stdint.h>
#include <string.h>

#include "sha256.h"

CAMLprim value caml_spice_digest_sha256_string(value input)
{
  CAMLparam1(input);
  CAMLlocal1(output);
  struct sha256_ctx ctx;
  mlsize_t len = caml_string_length(input);

  output = caml_alloc_string(SHA256_DIGEST_SIZE);
  const uint8_t *data = (const uint8_t *)String_val(input);
  spice_sha256_init(&ctx);
  while (len > 0) {
    uint32_t chunk =
        len > (mlsize_t)UINT32_MAX ? UINT32_MAX : (uint32_t)len;
    spice_sha256_update(&ctx, (uint8_t *)data, chunk);
    data += chunk;
    len -= chunk;
  }
  spice_sha256_finalize(&ctx, (uint8_t *)String_val(output));
  CAMLreturn(output);
}
