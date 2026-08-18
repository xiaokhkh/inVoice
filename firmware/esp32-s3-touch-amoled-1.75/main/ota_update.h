#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t ota_update_init(void);
esp_err_t ota_update_confirm_running_image(void);
void ota_update_set_input_diagnostics(uint32_t trigger_sources,
                                      bool touch_raw, bool touch_stable,
                                      bool pwr_raw, bool pwr_stable,
                                      bool pwr_armed);

uint16_t ota_update_get_report(uint8_t report_id, uint8_t report_type,
                               uint8_t *buffer, uint16_t requested_length,
                               void *context);
void ota_update_set_report(uint8_t report_id, uint8_t report_type,
                           const uint8_t *buffer, uint16_t buffer_size,
                           void *context);

#ifdef __cplusplus
}
#endif
