#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define MLX_MIC_SAMPLE_RATE 24000

esp_err_t audio_power_init(void);
esp_err_t audio_input_init(void);
esp_err_t audio_input_read(uint8_t *buffer, size_t length, size_t *bytes_read);
void audio_input_set_muted(bool muted);
bool audio_input_is_muted(void);

#ifdef __cplusplus
}
#endif
