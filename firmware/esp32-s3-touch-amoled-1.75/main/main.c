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
#include "ota_update.h"
#include "usb_device_uac.h"

#define PWR_BUTTON_PIN IO_EXPANDER_PIN_NUM_4
#define INPUT_SCAN_MS 20
#define TOUCH_DEBOUNCE_MS 40
#define BUTTON_DEBOUNCE_MS 100
#define DEBOUNCE_SAMPLES(milliseconds) \
    (((milliseconds) + INPUT_SCAN_MS - 1) / INPUT_SCAN_MS)
#define TOUCH_DEBOUNCE_SAMPLES DEBOUNCE_SAMPLES(TOUCH_DEBOUNCE_MS)
#define BUTTON_DEBOUNCE_SAMPLES DEBOUNCE_SAMPLES(BUTTON_DEBOUNCE_MS)
#define CONTROL_STATE_SYNC_MS 250
#define TOUCH_HOLD_MS 250
#define SUBMIT_PULSE_MS 40

static const char *TAG = "mlx_voice_mic";
static atomic_bool s_ui_ready;
static atomic_bool s_usb_mounted;
static atomic_bool s_clipboard_pressed;
static atomic_bool s_return_pressed;
static atomic_bool s_touch_pressed_raw;
static atomic_uint s_trigger_sources;
static SemaphoreHandle_t s_trigger_mutex;

typedef struct {
    bool stable;
    bool candidate;
    uint8_t candidate_samples;
} input_debouncer_t;

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
                atomic_load(&s_clipboard_pressed),
                atomic_load(&s_return_pressed)
            );
        }
    } else if (current_sources != 0 && next_sources == 0) {
        ret = uac_device_send_controls(
            false,
            atomic_load(&s_clipboard_pressed),
            atomic_load(&s_return_pressed)
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
            pressed,
            atomic_load(&s_return_pressed)
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

static bool set_return_pressed(bool pressed, bool force)
{
    if (xSemaphoreTake(s_trigger_mutex, pdMS_TO_TICKS(100)) != pdTRUE) {
        return false;
    }

    const bool current = atomic_load(&s_return_pressed);
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
            atomic_load(&s_clipboard_pressed),
            pressed
        );
    }

    if (ret == ESP_OK || force) {
        atomic_store(&s_return_pressed, force ? false : pressed);
        ESP_LOGI(TAG, "Return key %s",
                 (!force && pressed) ? "pressed" : "released");
    }
    xSemaphoreGive(s_trigger_mutex);
    return ret == ESP_OK || force;
}

static void pulse_return(void)
{
    // Do not submit an input field while a PTT control is still held.
    if (atomic_load(&s_trigger_sources) != 0 ||
        !set_return_pressed(true, false)) {
        return;
    }
    vTaskDelay(pdMS_TO_TICKS(SUBMIT_PULSE_MS));
    (void)set_return_pressed(false, false);
}

static void sync_control_state(void)
{
    if (!atomic_load(&s_usb_mounted) ||
        xSemaphoreTake(s_trigger_mutex, pdMS_TO_TICKS(20)) != pdTRUE) {
        return;
    }
    (void)uac_device_send_controls(
        atomic_load(&s_trigger_sources) != 0,
        atomic_load(&s_clipboard_pressed),
        atomic_load(&s_return_pressed)
    );
    xSemaphoreGive(s_trigger_mutex);
}

static void touch_trigger(bool pressed)
{
    // LVGL events are treated as raw samples. A short touch-controller glitch
    // must not create a recording Session, especially on noisy USB power.
    atomic_store(&s_touch_pressed_raw, pressed);
}

static bool debounce_input(input_debouncer_t *debouncer, bool raw,
                           uint8_t required_samples)
{
    if (raw == debouncer->stable) {
        debouncer->candidate = raw;
        debouncer->candidate_samples = 0;
        return debouncer->stable;
    }

    if (raw != debouncer->candidate) {
        debouncer->candidate = raw;
        debouncer->candidate_samples = 1;
        return debouncer->stable;
    }

    if (debouncer->candidate_samples < required_samples) {
        ++debouncer->candidate_samples;
    }
    if (debouncer->candidate_samples >= required_samples) {
        debouncer->stable = raw;
        debouncer->candidate_samples = 0;
    }
    return debouncer->stable;
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
        set_return_pressed(false, true);
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

    input_debouncer_t touch_debouncer = {0};
    input_debouncer_t pwr_debouncer = {0};
    input_debouncer_t boot_debouncer = {0};
    bool touch_was_pressed = false;
    bool touch_hold_active = false;
    bool pwr_pressed_raw = false;
    bool pwr_armed = false;
    bool pwr_wait_logged = false;
    TickType_t touch_pressed_at = 0;
    TickType_t last_control_sync = xTaskGetTickCount();
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(INPUT_SCAN_MS));

        const TickType_t now = xTaskGetTickCount();

        const bool touch_pressed = debounce_input(
            &touch_debouncer, atomic_load(&s_touch_pressed_raw),
            TOUCH_DEBOUNCE_SAMPLES);
        if (touch_pressed && !touch_was_pressed) {
            touch_was_pressed = true;
            touch_hold_active = false;
            touch_pressed_at = now;
        } else if (!touch_pressed && touch_was_pressed) {
            touch_was_pressed = false;
            if (touch_hold_active) {
                (void)set_trigger_source(TRIGGER_SOURCE_TOUCH, false, false);
                touch_hold_active = false;
            } else {
                pulse_return();
            }
        }

        if (touch_pressed && !touch_hold_active &&
            now - touch_pressed_at >= pdMS_TO_TICKS(TOUCH_HOLD_MS)) {
            touch_hold_active = true;
            (void)set_trigger_source(TRIGGER_SOURCE_TOUCH, true, false);
        }

        const bool boot_pressed = debounce_input(
            &boot_debouncer, gpio_get_level(GPIO_NUM_0) == 0,
            BUTTON_DEBOUNCE_SAMPLES);
        if (boot_pressed != atomic_load(&s_clipboard_pressed)) {
            set_clipboard_pressed(boot_pressed, false);
        }

        if (expander != NULL) {
            uint32_t level_mask = 0;
            if (esp_io_expander_get_level(expander, PWR_BUTTON_PIN, &level_mask) == ESP_OK) {
                pwr_pressed_raw = (level_mask & PWR_BUTTON_PIN) != 0;
                const bool pwr_pressed = debounce_input(
                    &pwr_debouncer, pwr_pressed_raw,
                    BUTTON_DEBOUNCE_SAMPLES);
                const bool pwr_active =
                    (atomic_load(&s_trigger_sources) & TRIGGER_SOURCE_PWR) != 0;

                // A dock or the PMIC can leave EXIO4 high while USB settles.
                // Require a stable released level after every connection before
                // treating a later high level as a real PWR press.
                if (!atomic_load(&s_usb_mounted)) {
                    pwr_armed = false;
                    pwr_wait_logged = false;
                    if (pwr_active) {
                        set_trigger_source(TRIGGER_SOURCE_PWR, false, false);
                    }
                } else if (!pwr_pressed) {
                    pwr_armed = true;
                    pwr_wait_logged = false;
                    if (pwr_active) {
                        set_trigger_source(TRIGGER_SOURCE_PWR, false, false);
                    }
                } else if (pwr_armed && !pwr_active) {
                    set_trigger_source(TRIGGER_SOURCE_PWR, true, false);
                } else if (!pwr_armed && !pwr_wait_logged) {
                    ESP_LOGW(TAG, "Ignoring PWR high until a stable release");
                    pwr_wait_logged = true;
                }
            }
        }

        ota_update_set_input_diagnostics(
            atomic_load(&s_trigger_sources),
            atomic_load(&s_touch_pressed_raw), touch_pressed,
            pwr_pressed_raw, pwr_debouncer.stable, pwr_armed);

        if (now - last_control_sync >= pdMS_TO_TICKS(CONTROL_STATE_SYNC_MS)) {
            sync_control_state();
            last_control_sync = now;
        }
    }
}

void app_main(void)
{
    atomic_store(&s_ui_ready, false);
    atomic_store(&s_usb_mounted, false);
    atomic_store(&s_clipboard_pressed, false);
    atomic_store(&s_return_pressed, false);
    atomic_store(&s_touch_pressed_raw, false);
    atomic_store(&s_trigger_sources, 0);
    s_trigger_mutex = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(s_trigger_mutex != NULL ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(audio_power_init());
    ESP_ERROR_CHECK(ota_update_init());

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
        .hid_get_report_cb = ota_update_get_report,
        .hid_set_report_cb = ota_update_set_report,
        .cb_ctx = NULL,
    };
    ret = uac_device_init(&usb_config);
    if (ret != ESP_OK) {
        jam_ui_set_error("USB AUDIO ERROR");
        ESP_LOGE(TAG, "USB UAC init failed: %s", esp_err_to_name(ret));
        return;
    }

    ret = ota_update_confirm_running_image();
    if (ret != ESP_OK) {
        ESP_LOGW(TAG, "Unable to confirm OTA image: %s", esp_err_to_name(ret));
    }

    xTaskCreate(physical_button_task, "physical_buttons", 3072, NULL, 4, NULL);
    ESP_LOGI(TAG, "MLX Voice Mic ready: hold touch/PWR to talk; tap touch for Return; press BOOT for clipboard");
}
