#ifndef CLOUDREVE_FFI_H
#define CLOUDREVE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t cloudreve_core_abi_version(void);
int32_t cloudreve_validate_local_identifier(const char *value, const char *prefix);

#ifdef __cplusplus
}
#endif

#endif

