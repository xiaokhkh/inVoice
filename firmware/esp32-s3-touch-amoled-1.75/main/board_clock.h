#pragma once

#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint16_t year;
    uint8_t month;
    uint8_t day;
    uint8_t weekday;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} board_clock_time_t;

esp_err_t board_clock_init(void);
esp_err_t board_clock_get(board_clock_time_t *time_value);
esp_err_t board_clock_set(const board_clock_time_t *time_value);

#ifdef __cplusplus
}
#endif
