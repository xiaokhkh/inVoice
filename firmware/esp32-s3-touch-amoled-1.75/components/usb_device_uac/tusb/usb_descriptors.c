/*
 * The MIT License (MIT)
 *
 * Copyright (c) 2019 Ha Thach (tinyusb.org)
 * Copyright (c) 2020 Jerzy Kasenbreg
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#include "tusb.h"
#include "uac_descriptors.h"
#include "voiceops_ota_protocol.h"

//--------------------------------------------------------------------+
// Device Descriptors
//--------------------------------------------------------------------+
tusb_desc_device_t const desc_device = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,

    // Use Interface Association Descriptor (IAD) for CDC
    // As required by USB Specs IAD's subclass must be common class (2) and protocol must be IAD (1)
    .bDeviceClass       = TUSB_CLASS_MISC,
    .bDeviceSubClass    = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol    = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,

    .idVendor           = CONFIG_UAC_TUSB_VID,
    .idProduct          = CONFIG_UAC_TUSB_PID,
    .bcdDevice          = 0x0100,

    .iManufacturer      = 0x01,
    .iProduct           = 0x02,
    .iSerialNumber      = 0x03,

    .bNumConfigurations = 0x01
};

// Invoked when received GET DEVICE DESCRIPTOR
// Application return pointer to descriptor
uint8_t const *tud_descriptor_device_cb(void)
{
    return (uint8_t const *)&desc_device;
}

//--------------------------------------------------------------------+
// Configuration Descriptor
//--------------------------------------------------------------------+
#define CONFIG_TOTAL_LEN        (TUD_CONFIG_DESC_LEN + CFG_TUD_AUDIO * TUD_AUDIO_DEVICE_DESC_LEN + 2 * TUD_HID_DESC_LEN)
#define EPNUM_AUDIO_OUT   0x01
#define EPNUM_AUDIO_FB    0x81
#define EPNUM_AUDIO_IN    0x82
#define EPNUM_HID_IN      0x83
#define EPNUM_HID_OTA_IN  0x84
#define HID_KEYBOARD_EP_SIZE 8

static uint8_t const desc_hid_report[] = {
    TUD_HID_REPORT_DESC_KEYBOARD()
};

static uint8_t const desc_hid_ota_report[] = {
    0x06, 0x00, 0xff,       // Usage Page (Vendor Defined 0xff00)
    0x09, 0x01,             // Usage (1)
    0xa1, 0x01,             // Collection (Application)
    0x15, 0x00,             // Logical Minimum (0)
    0x26, 0xff, 0x00,       // Logical Maximum (255)
    0x75, 0x08,             // Report Size (8 bits)
    0x95, VOICEOPS_OTA_REPORT_SIZE, // Report Count (64 bytes)
    0x09, 0x01,             // Usage (1)
    0xb1, 0x02,             // Feature (Data, Variable, Absolute)
    0xc0,                   // End Collection
};

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance)
{
    return instance == 0 ? desc_hid_report : desc_hid_ota_report;
}

uint8_t const desc_configuration[] = {
    // Config number, interface count, string index, total length, attribute, power in mA
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0x00, 100),
    // Interface number, string index, EP Out & EP In address, EP size
    TUD_AUDIO_DESCRIPTOR(ITF_NUM_AUDIO_CONTROL, 4, EPNUM_AUDIO_OUT, EPNUM_AUDIO_IN, EPNUM_AUDIO_FB),
    // A dedicated keyboard interface emits VoiceOps F13/F14 control reports.
    TUD_HID_DESCRIPTOR(ITF_NUM_HID_TRIGGER, 6, HID_ITF_PROTOCOL_KEYBOARD,
                       sizeof(desc_hid_report), EPNUM_HID_IN, HID_KEYBOARD_EP_SIZE, 10),
    // USB-only updater; this interface never emits keyboard reports.
    TUD_HID_DESCRIPTOR(ITF_NUM_HID_OTA, 7, HID_ITF_PROTOCOL_NONE,
                       sizeof(desc_hid_ota_report), EPNUM_HID_OTA_IN,
                       VOICEOPS_OTA_REPORT_SIZE, 10),
};

// Invoked when received GET CONFIGURATION DESCRIPTOR
// Application return pointer to descriptor
// Descriptor contents must exist long enough for transfer to complete
uint8_t const *tud_descriptor_configuration_cb(uint8_t index)
{
    (void)index; // for multiple configurations
    return desc_configuration;
}

//--------------------------------------------------------------------+
// String Descriptors
//--------------------------------------------------------------------+

// array of pointer to string descriptors
char const *string_desc_arr [] = {
    (const char[]) { 0x09, 0x04 },  // 0: is supported language is English (0x0409)
    CONFIG_UAC_TUSB_MANUFACTURER,       // 1: Manufacturer
    CONFIG_UAC_TUSB_PRODUCT,            // 2: Product
    CONFIG_UAC_TUSB_SERIAL_NUM,         // 3: Serials, should use chip ID
    "usb uac",                      // 4: UAC control Interface
#if SPEAK_CHANNEL_NUM
    "speaker",                     // 5: Speak Interface
#endif
#if MIC_CHANNEL_NUM
    CONFIG_UAC_TUSB_PRODUCT,         // Mic Interface
#endif
    "Voice Controls",               // HID push-to-talk and clipboard controls
    "Firmware Update",              // Vendor HID feature-report OTA interface
};

static uint16_t _desc_str[32];

// Invoked when received GET STRING DESCRIPTOR request
// Application return pointer to descriptor, whose contents must exist long enough for transfer to complete
uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid)
{
    (void)langid;

    uint8_t chr_count;

    if (index == 0) {
        memcpy(&_desc_str[1], string_desc_arr[0], 2);
        chr_count = 1;
    } else {

        if (!(index < sizeof(string_desc_arr) / sizeof(string_desc_arr[0]))) {
            return NULL;
        }

        const char *str = string_desc_arr[index];

        // Cap at max char
        chr_count = (uint8_t) strlen(str);
        if (chr_count > 31) {
            chr_count = 31;
        }

        for (uint8_t i = 0; i < chr_count; i++) {
            _desc_str[1 + i] = str[i];
        }
    }

    // first byte is length (including header), second byte is string type
    _desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * chr_count + 2));

    return _desc_str;
}
