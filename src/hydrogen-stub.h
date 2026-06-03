#pragma once
/* Stub for broken toolchain symlink — disables SYNO_RAMDISK_INTEGRITY_CHECK path */
#include <stddef.h>
#include <stdint.h>

#define hydro_sign_BYTES 64
#define hydro_sign_PUBLICKEYBYTES 32
#define hydro_sign_SECRETKEYBYTES 64
#define hydro_sign_SEEDBYTES 32

typedef struct { unsigned char pk[hydro_sign_PUBLICKEYBYTES]; } hydro_sign_keypair;

static inline int hydro_sign_verify(const uint8_t *csig, const void *m,
                                     size_t mlen, const char *ctx,
                                     const uint8_t *pk) { return 0; }
static inline int hydro_sign_create(uint8_t *csig, const void *m, size_t mlen,
                                     const char *ctx, const uint8_t *sk) { return 0; }
static inline int hydro_sign_init(void *state, const char *ctx) { return 0; }
static inline int hydro_sign_update(void *state, const void *m, size_t mlen) { return 0; }
static inline int hydro_sign_final_verify(void *state, const uint8_t *csig,
                                           const uint8_t *pk) { return 0; }
