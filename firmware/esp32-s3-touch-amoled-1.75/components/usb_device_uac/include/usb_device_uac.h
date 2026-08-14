/*
 * SPDX-FileCopyrightText: 2024 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#pragma once

#include <stdbool.h>
#include <stdint.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef esp_err_t (*uac_output_cb_t)(uint8_t *buf, size_t len, void *cb_ctx);
typedef esp_err_t (*uac_input_cb_t)(uint8_t *buf, size_t len, size_t *bytes_read, void *cb_ctx);
typedef void (*uac_set_mute_cb_t)(uint32_t mute, void *cb_ctx);
typedef void (*uac_set_volume_cb_t)(uint32_t volume, void *cb_ctx);
typedef uint16_t (*uac_hid_get_report_cb_t)(uint8_t report_id,
                                            uint8_t report_type,
                                            uint8_t *buffer,
                                            uint16_t requested_length,
                                            void *cb_ctx);
typedef void (*uac_hid_set_report_cb_t)(uint8_t report_id,
                                        uint8_t report_type,
                                        const uint8_t *buffer,
                                        uint16_t buffer_size,
                                        void *cb_ctx);

typedef enum {
    UAC_DEVICE_EVENT_MOUNTED,
    UAC_DEVICE_EVENT_UNMOUNTED,
    UAC_DEVICE_EVENT_SUSPENDED,
    UAC_DEVICE_EVENT_RESUMED,
    UAC_DEVICE_EVENT_MIC_OPENED,
    UAC_DEVICE_EVENT_MIC_CLOSED,
} uac_device_event_t;

typedef void (*uac_event_cb_t)(uac_device_event_t event, void *cb_ctx);

/**
 * @brief USB UAC Device Config
 *
 */
typedef struct  {
    bool skip_tinyusb_init;                      /*!< if true, the Tinyusb and usb phy will not be initialized */
    uac_output_cb_t output_cb;                   /*!< callback function for UAC data output, if NULL, output will be disabled */
    uac_input_cb_t input_cb;                     /*!< callback function for UAC data input, if NULL, input will be disabled */
    uac_set_mute_cb_t set_mute_cb;               /*!< callback function for set mute, if NULL, the set mute request will be ignored */
    uac_set_volume_cb_t set_volume_cb;           /*!< callback function for set volume, if NULL, the set volume request will be ignored */
    uac_event_cb_t event_cb;                     /*!< callback for USB and microphone interface state */
    uac_hid_get_report_cb_t hid_get_report_cb;   /*!< vendor HID feature report reader */
    uac_hid_set_report_cb_t hid_set_report_cb;   /*!< vendor HID feature report writer */
    void *cb_ctx;                                /*!< callback context, for user specific usage */
#if CONFIG_USB_DEVICE_UAC_AS_PART
    int spk_itf_num;                             /*!< If CONFIG_USB_DEVICE_UAC_AS_PART is enabled, you need to provide the speaker interface number */
    int mic_itf_num;                             /*!< If CONFIG_USB_DEVICE_UAC_AS_PART is enabled, you need to provide the mic interface number */
#endif
} uac_device_config_t;

/**
 * @brief Initialize the USB Audio Class (UAC) device.
 *
 * @param config Pointer to the UAC device configuration structure.
 * @return
 *       - ESP_OK on success
 *       - ESP_FAIL on failure
 */
esp_err_t uac_device_init(uac_device_config_t *config);

/**
 * Send the complete VoiceOps HID control state.
 *
 * F13 represents push-to-talk and F14 represents the clipboard panel. Sending
 * both states in one report prevents either control from releasing the other
 * when they overlap.
 */
esp_err_t uac_device_send_controls(bool voice_pressed, bool clipboard_pressed);

#ifdef __cplusplus
}
#endif
