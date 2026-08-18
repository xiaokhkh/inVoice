#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*jam_ui_trigger_cb_t)(bool pressed);

esp_err_t jam_ui_init(lv_display_t *display, jam_ui_trigger_cb_t trigger_cb);
void jam_ui_set_usb_connected(bool connected);
void jam_ui_set_muted(bool muted);
void jam_ui_set_trigger_active(bool active);
void jam_ui_note_audio(uint8_t level_percent);
void jam_ui_set_local_time(uint8_t hour, uint8_t minute, bool valid);
void jam_ui_set_error(const char *message);

#ifdef __cplusplus
}
#endif
