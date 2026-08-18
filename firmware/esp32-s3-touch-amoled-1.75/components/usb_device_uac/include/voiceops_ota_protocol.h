/*
 * VoiceOps USB OTA wire protocol.
 *
 * Every request and response is one 64-byte HID feature report. The protocol
 * intentionally lives on its own vendor-defined HID interface so firmware
 * updates can never be interpreted as keyboard input.
 */

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VOICEOPS_OTA_MAGIC              UINT32_C(0x41544f56) /* "VOTA" */
#define VOICEOPS_OTA_PROTOCOL_VERSION   1U
#define VOICEOPS_OTA_REPORT_SIZE        64U
#define VOICEOPS_OTA_PAYLOAD_SIZE       44U
#define VOICEOPS_OTA_VENDOR_USAGE_PAGE  0xff00U
#define VOICEOPS_OTA_VENDOR_USAGE       0x0001U

typedef enum {
    VOICEOPS_OTA_COMMAND_STATUS = 0,
    VOICEOPS_OTA_COMMAND_BEGIN = 1,
    VOICEOPS_OTA_COMMAND_DATA = 2,
    VOICEOPS_OTA_COMMAND_FINISH = 3,
    VOICEOPS_OTA_COMMAND_ABORT = 4,
    VOICEOPS_OTA_COMMAND_REBOOT = 5,
    VOICEOPS_OTA_COMMAND_SYNC_CLOCK = 6,
} voiceops_ota_command_t;

typedef enum {
    VOICEOPS_OTA_STATE_IDLE = 0,
    VOICEOPS_OTA_STATE_RECEIVING = 1,
    VOICEOPS_OTA_STATE_READY_TO_REBOOT = 2,
    VOICEOPS_OTA_STATE_ERROR = 3,
} voiceops_ota_state_t;

typedef enum {
    VOICEOPS_OTA_STATUS_OK = 0,
    VOICEOPS_OTA_STATUS_BAD_MAGIC = 1,
    VOICEOPS_OTA_STATUS_BAD_VERSION = 2,
    VOICEOPS_OTA_STATUS_BAD_COMMAND = 3,
    VOICEOPS_OTA_STATUS_BAD_STATE = 4,
    VOICEOPS_OTA_STATUS_BAD_LENGTH = 5,
    VOICEOPS_OTA_STATUS_OFFSET_MISMATCH = 6,
    VOICEOPS_OTA_STATUS_IMAGE_TOO_LARGE = 7,
    VOICEOPS_OTA_STATUS_NO_PARTITION = 8,
    VOICEOPS_OTA_STATUS_FLASH_ERROR = 9,
    VOICEOPS_OTA_STATUS_CRC_MISMATCH = 10,
    VOICEOPS_OTA_STATUS_INVALID_IMAGE = 11,
    VOICEOPS_OTA_STATUS_QUEUE_FULL = 12,
    VOICEOPS_OTA_STATUS_CLOCK_ERROR = 13,
} voiceops_ota_status_t;

#pragma pack(push, 1)
typedef struct {
    uint8_t year_since_2000;
    uint8_t month;
    uint8_t day;
    uint8_t weekday;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} voiceops_clock_payload_t;

typedef struct {
    uint32_t magic;
    uint8_t version;
    uint8_t command;
    uint16_t payload_length;
    uint32_t sequence;
    uint32_t offset;
    uint32_t value;
    uint8_t payload[VOICEOPS_OTA_PAYLOAD_SIZE];
} voiceops_ota_request_t;

typedef struct {
    uint32_t magic;
    uint8_t version;
    uint8_t state;
    uint8_t last_command;
    uint8_t reserved0;
    uint32_t status;
    uint32_t sequence;
    uint32_t next_offset;
    uint32_t total_size;
    uint32_t running_partition_subtype;
    uint32_t target_partition_subtype;
    char running_version[16];
    uint8_t reserved[16];
} voiceops_ota_response_t;
#pragma pack(pop)

_Static_assert(sizeof(voiceops_ota_request_t) == VOICEOPS_OTA_REPORT_SIZE,
               "OTA request must be one HID feature report");
_Static_assert(sizeof(voiceops_ota_response_t) == VOICEOPS_OTA_REPORT_SIZE,
               "OTA response must be one HID feature report");
_Static_assert(sizeof(voiceops_clock_payload_t) == 7,
               "Clock payload wire size changed");

static inline uint32_t voiceops_ota_crc32_update(uint32_t crc,
                                                 const uint8_t *data,
                                                 size_t length)
{
    for (size_t index = 0; index < length; ++index) {
        crc ^= data[index];
        for (unsigned bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) &
                                (uint32_t)-(int32_t)(crc & 1U));
        }
    }
    return crc;
}

#ifdef __cplusplus
}
#endif
