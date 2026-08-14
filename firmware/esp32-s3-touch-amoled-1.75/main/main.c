#include <stdatomic.h>
#include <stdlib.h>
#include "audio_input.h"
#include "bsp/esp-bsp.h"
#include "driver/gpio.h"
#include "esp_check.h"
#include "esp_io_expander.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "jam_ui.h"
#include "usb_device_uac.h"

#define PWR_BUTTON_PIN IO_EXPANDER_PIN_NUM_4

static const char *TAG = "mlx_voice_mic";
static atomic_bool s_ui_ready;
static atomic_bool s_usb_mounted;
static atomic_bool s_clipboard_pressed;
static atomic_uint s_trigger_sources;
static SemaphoreHandle_t s_trigger_mutex;

typedef enum {
    TRIGGER_SOURCE_TOUCH = 1U << 0,
    TRIGGER_SOURCE_PWR   = 1U << 1,
} trigger_source_t;

static void set_muted(bool muted)
{
    audio_input_set_muted(muted);
    if (atomic_load(&s_ui_ready)) {
        jam_ui_set_muted(muted);
    }
}

static bool set_trigger_source(trigger_source_t source, bool pressed, bool force)
{
    if (xSemaphoreTake(s_trigger_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return false;
    }

    const uint32_t current_sources = atomic_load(&s_trigger_sources);
    const uint32_t next_sources = pressed
        ? current_sources | (uint32_t)source
        : current_sources & ~(uint32_t)source;
    if (next_sources == current_sources) {
        xSemaphoreGive(s_trigger_mutex);
        return true;
    }

    esp_err_t ret = ESP_OK;
    if (current_sources == 0 && next_sources != 0) {
        if (!atomic_load(&s_usb_mounted) || audio_input_is_muted()) {
            ret = ESP_ERR_INVALID_STATE;
        } else {
            ret = uac_device_send_controls(
                true,
                atomic_load(&s_clipboard_pressed)
            );
        }
    } else if (current_sources != 0 && next_sources == 0) {
        ret = uac_device_send_controls(
            false,
            atomic_load(&s_clipboard_pressed)
        );
    }

    if (ret == ESP_OK || force) {
        atomic_store(&s_trigger_sources, force ? 0 : next_sources);
        if (atomic_load(&s_ui_ready)) {
            jam_ui_set_trigger_active(!force && next_sources != 0);
        }
        ESP_LOGI(TAG, "VoiceOps trigger %s, sources=0x%02lx",
                 (!force && next_sources != 0) ? "pressed" : "released",
                 (unsigned long)(force ? 0 : next_sources));
    }
    xSemaphoreGive(s_trigger_mutex);
    return ret == ESP_OK || force;
}

static bool set_clipboard_pressed(bool pressed, bool force)
{
    if (xSemaphoreTake(s_trigger_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return false;
    }

    const bool current = atomic_load(&s_clipboard_pressed);
    if (current == pressed) {
        xSemaphoreGive(s_trigger_mutex);
        return true;
    }

    esp_err_t ret = ESP_OK;
    if (!atomic_load(&s_usb_mounted)) {
        ret = ESP_ERR_INVALID_STATE;
    } else {
        ret = uac_device_send_controls(
            atomic_load(&s_trigger_sources) != 0,
            pressed
        );
    }

    if (ret == ESP_OK || force) {
        atomic_store(&s_clipboard_pressed, force ? false : pressed);
        ESP_LOGI(TAG, "Clipboard trigger %s",
                 (!force && pressed) ? "pressed" : "released");
    }
    xSemaphoreGive(s_trigger_mutex);
    return ret == ESP_OK || force;
}

static void touch_trigger(bool pressed)
{
    set_trigger_source(TRIGGER_SOURCE_TOUCH, pressed, false);
}

static uint8_t calculate_level(const uint8_t *buffer, size_t length)
{
    const int16_t *samples = (const int16_t *)buffer;
    const size_t count = length / sizeof(int16_t);
    int32_t peak = 0;
    for (size_t i = 0; i < count; ++i) {
        int32_t value = samples[i];
        if (value < 0) {
            value = -value;
        }
        if (value > peak) {
            peak = value;
        }
    }

    // Normal near-field speech now occupies a useful portion of the full dial.
    const int32_t percent = peak * 100 / 3000;
    return (uint8_t)(percent > 100 ? 100 : percent);
}

static esp_err_t uac_input_cb(uint8_t *buffer, size_t length, size_t *bytes_read, void *context)
{
    (void)context;
    esp_err_t ret = audio_input_read(buffer, length, bytes_read);
    if (ret != ESP_OK) {
        if (atomic_load(&s_ui_ready)) {
            jam_ui_set_error("AUDIO READ ERROR");
        }
        return ret;
    }
    if (atomic_load(&s_ui_ready)) {
        jam_ui_note_audio(audio_input_is_muted() ? 0 : calculate_level(buffer, *bytes_read));
    }
    return ESP_OK;
}

static void uac_mute_cb(uint32_t mute, void *context)
{
    (void)context;
    set_muted(mute != 0);
}

static void uac_volume_cb(uint32_t volume, void *context)
{
    (void)volume;
    (void)context;
}

static void uac_event_cb(uac_device_event_t event, void *context)
{
    (void)context;
    switch (event) {
    case UAC_DEVICE_EVENT_MOUNTED:
    case UAC_DEVICE_EVENT_RESUMED:
        atomic_store(&s_usb_mounted, true);
        if (atomic_load(&s_ui_ready)) {
            jam_ui_set_usb_connected(true);
        }
        break;
    case UAC_DEVICE_EVENT_UNMOUNTED:
    case UAC_DEVICE_EVENT_SUSPENDED:
        atomic_store(&s_usb_mounted, false);
        set_trigger_source((trigger_source_t)atomic_load(&s_trigger_sources), false, true);
        set_clipboard_pressed(false, true);
        if (atomic_load(&s_ui_ready)) {
            jam_ui_set_usb_connected(false);
        }
        break;
    case UAC_DEVICE_EVENT_MIC_OPENED:
        if (atomic_load(&s_ui_ready)) {
            jam_ui_set_usb_connected(true);
        }
        break;
    case UAC_DEVICE_EVENT_MIC_CLOSED:
        break;
    }
}

static void physical_button_task(void *context)
{
    (void)context;
    const gpio_config_t boot_config = {
        .pin_bit_mask = 1ULL << GPIO_NUM_0,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&boot_config));

    esp_io_expander_handle_t expander = bsp_io_expander_init();
    if (expander == NULL ||
        esp_io_expander_set_dir(expander, PWR_BUTTON_PIN, IO_EXPANDER_INPUT) != ESP_OK) {
        ESP_LOGE(TAG, "PWR button input init failed");
        expander = NULL;
    }

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(20));

        const bool boot_pressed = gpio_get_level(GPIO_NUM_0) == 0;
        if (boot_pressed != atomic_load(&s_clipboard_pressed)) {
            set_clipboard_pressed(boot_pressed, false);
        }

        if (expander != NULL) {
            uint32_t level_mask = 0;
            if (esp_io_expander_get_level(expander, PWR_BUTTON_PIN, &level_mask) == ESP_OK) {
                const bool pwr_pressed = (level_mask & PWR_BUTTON_PIN) != 0;
                const bool pwr_active =
                    (atomic_load(&s_trigger_sources) & TRIGGER_SOURCE_PWR) != 0;
                if (pwr_pressed != pwr_active) {
                    set_trigger_source(TRIGGER_SOURCE_PWR, pwr_pressed, false);
                }
            }
        }
    }
}

void app_main(void)
{
    atomic_store(&s_ui_ready, false);
    atomic_store(&s_usb_mounted, false);
    atomic_store(&s_clipboard_pressed, false);
    atomic_store(&s_trigger_sources, 0);
    s_trigger_mutex = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(s_trigger_mutex != NULL ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(audio_power_init());

    lv_display_t *display = bsp_display_start();
    ESP_ERROR_CHECK(display != NULL ? ESP_OK : ESP_FAIL);
    ESP_ERROR_CHECK(jam_ui_init(display, touch_trigger));
    atomic_store(&s_ui_ready, true);

    esp_err_t ret = audio_input_init();
    if (ret != ESP_OK) {
        jam_ui_set_error("MIC INIT ERROR");
        ESP_LOGE(TAG, "microphone init failed: %s", esp_err_to_name(ret));
        return;
    }

    uac_device_config_t usb_config = {
        .skip_tinyusb_init = false,
        .output_cb = NULL,
        .input_cb = uac_input_cb,
        .set_mute_cb = uac_mute_cb,
        .set_volume_cb = uac_volume_cb,
        .event_cb = uac_event_cb,
        .cb_ctx = NULL,
    };
    ret = uac_device_init(&usb_config);
    if (ret != ESP_OK) {
        jam_ui_set_error("USB AUDIO ERROR");
        ESP_LOGE(TAG, "USB UAC init failed: %s", esp_err_to_name(ret));
        return;
    }

    xTaskCreate(physical_button_task, "physical_buttons", 3072, NULL, 4, NULL);
    ESP_LOGI(TAG, "MLX Voice Mic ready: hold touch/PWR to talk; press BOOT for clipboard");
}
