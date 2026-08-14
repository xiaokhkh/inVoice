#pragma once

#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t asset_store_init(void);
esp_err_t asset_store_get(const char *name, const uint8_t **data, size_t *size);

#ifdef __cplusplus
}
#endif
