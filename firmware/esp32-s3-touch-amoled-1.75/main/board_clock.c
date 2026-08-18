#include "board_clock.h"

#include <stdbool.h>
#include <string.h>

#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "esp_check.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define PCF85063_ADDRESS 0x51
#define PCF85063_CTRL1_REG 0x00
#define PCF85063_SECONDS_REG 0x04
#define PCF85063_CTRL1_STOP (1U << 5)
#define PCF85063_CTRL1_12_HOUR (1U << 1)
#define PCF85063_SECONDS_OS (1U << 7)

static const char *TAG = "board_clock";
static i2c_master_dev_handle_t s_rtc;
static SemaphoreHandle_t s_clock_mutex;

static uint8_t from_bcd(uint8_t value)
{
    return (uint8_t)(((value >> 4) * 10U) + (value & 0x0fU));
}

static uint8_t to_bcd(uint8_t value)
{
    return (uint8_t)(((value / 10U) << 4) | (value % 10U));
}

static bool valid_time(const board_clock_time_t *value)
{
    return value != NULL && value->year >= 2000 && value->year <= 2099 &&
        value->month >= 1 && value->month <= 12 &&
        value->day >= 1 && value->day <= 31 &&
        value->weekday <= 6 && value->hour <= 23 &&
        value->minute <= 59 && value->second <= 59;
}

static esp_err_t read_registers(uint8_t reg, uint8_t *data, size_t length)
{
    return i2c_master_transmit_receive(s_rtc, &reg, 1, data, length, 1000);
}

static esp_err_t write_registers(uint8_t reg, const uint8_t *data, size_t length)
{
    uint8_t buffer[9];
    if (length > sizeof(buffer) - 1) {
        return ESP_ERR_INVALID_SIZE;
    }
    buffer[0] = reg;
    memcpy(buffer + 1, data, length);
    return i2c_master_transmit(s_rtc, buffer, length + 1, 1000);
}

esp_err_t board_clock_init(void)
{
    if (s_rtc != NULL) {
        return ESP_OK;
    }
    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "I2C init failed");

    const i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = PCF85063_ADDRESS,
        .scl_speed_hz = 400000,
    };
    ESP_RETURN_ON_ERROR(
        i2c_master_bus_add_device(bsp_i2c_get_handle(), &config, &s_rtc),
        TAG, "PCF85063 attach failed");

    s_clock_mutex = xSemaphoreCreateMutex();
    if (s_clock_mutex == NULL) {
        i2c_master_bus_rm_device(s_rtc);
        s_rtc = NULL;
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "PCF85063 clock ready");
    return ESP_OK;
}

esp_err_t board_clock_get(board_clock_time_t *time_value)
{
    if (s_rtc == NULL || s_clock_mutex == NULL || time_value == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (xSemaphoreTake(s_clock_mutex, pdMS_TO_TICKS(1000)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    uint8_t data[7] = {0};
    esp_err_t result = read_registers(PCF85063_SECONDS_REG, data, sizeof(data));
    xSemaphoreGive(s_clock_mutex);
    if (result != ESP_OK) {
        return result;
    }
    if ((data[0] & PCF85063_SECONDS_OS) != 0) {
        return ESP_ERR_INVALID_STATE;
    }

    const board_clock_time_t decoded = {
        .year = (uint16_t)(2000U + from_bcd(data[6])),
        .month = from_bcd(data[5] & 0x1fU),
        .day = from_bcd(data[3] & 0x3fU),
        .weekday = (uint8_t)(data[4] & 0x07U),
        .hour = from_bcd(data[2] & 0x3fU),
        .minute = from_bcd(data[1] & 0x7fU),
        .second = from_bcd(data[0] & 0x7fU),
    };
    if (!valid_time(&decoded)) {
        return ESP_ERR_INVALID_RESPONSE;
    }
    *time_value = decoded;
    return ESP_OK;
}

esp_err_t board_clock_set(const board_clock_time_t *time_value)
{
    if (s_rtc == NULL || s_clock_mutex == NULL) {
        return ESP_ERR_INVALID_STATE;
    }
    if (!valid_time(time_value)) {
        return ESP_ERR_INVALID_ARG;
    }
    if (xSemaphoreTake(s_clock_mutex, pdMS_TO_TICKS(1000)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }

    uint8_t control = 0;
    esp_err_t result = read_registers(PCF85063_CTRL1_REG, &control, 1);
    const bool control_read = result == ESP_OK;
    if (result == ESP_OK) {
        const uint8_t stopped = (uint8_t)(
            (control & ~PCF85063_CTRL1_12_HOUR) | PCF85063_CTRL1_STOP);
        result = write_registers(PCF85063_CTRL1_REG, &stopped, 1);
    }
    if (result == ESP_OK) {
        const uint8_t values[7] = {
            to_bcd(time_value->second),
            to_bcd(time_value->minute),
            to_bcd(time_value->hour),
            to_bcd(time_value->day),
            time_value->weekday,
            to_bcd(time_value->month),
            to_bcd((uint8_t)(time_value->year - 2000U)),
        };
        result = write_registers(PCF85063_SECONDS_REG, values, sizeof(values));
    }
    if (control_read) {
        const uint8_t running = (uint8_t)(
            control & ~(PCF85063_CTRL1_STOP | PCF85063_CTRL1_12_HOUR));
        const esp_err_t restart_result =
            write_registers(PCF85063_CTRL1_REG, &running, 1);
        if (result == ESP_OK) {
            result = restart_result;
        }
    }
    xSemaphoreGive(s_clock_mutex);

    if (result == ESP_OK) {
        ESP_LOGI(TAG, "clock set to %04u-%02u-%02u %02u:%02u:%02u",
                 time_value->year, time_value->month, time_value->day,
                 time_value->hour, time_value->minute, time_value->second);
    }
    return result;
}
