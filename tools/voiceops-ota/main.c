#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "voiceops_ota_protocol.h"

#define VOICEOPS_USB_VID 0x303a
#define VOICEOPS_USB_PID 0x4002

typedef struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
} ota_connection_t;

static const char *state_name(uint8_t state)
{
    switch ((voiceops_ota_state_t)state) {
    case VOICEOPS_OTA_STATE_IDLE: return "idle";
    case VOICEOPS_OTA_STATE_RECEIVING: return "receiving";
    case VOICEOPS_OTA_STATE_READY_TO_REBOOT: return "ready-to-reboot";
    case VOICEOPS_OTA_STATE_ERROR: return "error";
    }
    return "unknown";
}

static const char *status_name(uint32_t status)
{
    switch ((voiceops_ota_status_t)status) {
    case VOICEOPS_OTA_STATUS_OK: return "ok";
    case VOICEOPS_OTA_STATUS_BAD_MAGIC: return "bad protocol magic";
    case VOICEOPS_OTA_STATUS_BAD_VERSION: return "unsupported protocol version";
    case VOICEOPS_OTA_STATUS_BAD_COMMAND: return "unsupported command";
    case VOICEOPS_OTA_STATUS_BAD_STATE: return "invalid update state";
    case VOICEOPS_OTA_STATUS_BAD_LENGTH: return "invalid length";
    case VOICEOPS_OTA_STATUS_OFFSET_MISMATCH: return "offset mismatch";
    case VOICEOPS_OTA_STATUS_IMAGE_TOO_LARGE: return "image too large";
    case VOICEOPS_OTA_STATUS_NO_PARTITION: return "no inactive OTA slot";
    case VOICEOPS_OTA_STATUS_FLASH_ERROR: return "flash operation failed";
    case VOICEOPS_OTA_STATUS_CRC_MISMATCH: return "CRC mismatch";
    case VOICEOPS_OTA_STATUS_INVALID_IMAGE: return "invalid ESP image";
    case VOICEOPS_OTA_STATUS_QUEUE_FULL: return "device request queue full";
    case VOICEOPS_OTA_STATUS_CLOCK_ERROR: return "RTC update failed";
    }
    return "unknown device error";
}

static uint64_t monotonic_milliseconds(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000U + (uint64_t)value.tv_nsec / 1000000U;
}

static uint16_t next_chunk_size(uint32_t total_size, uint32_t offset)
{
    const uint32_t remaining = total_size - offset;
    return remaining > VOICEOPS_OTA_PAYLOAD_SIZE
        ? (uint16_t)VOICEOPS_OTA_PAYLOAD_SIZE
        : (uint16_t)remaining;
}

static void sleep_milliseconds(unsigned milliseconds)
{
    struct timespec delay = {
        .tv_sec = milliseconds / 1000U,
        .tv_nsec = (long)(milliseconds % 1000U) * 1000000L,
    };
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
    }
}

static void dictionary_set_int(CFMutableDictionaryRef dictionary,
                               CFStringRef key, int value)
{
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault,
                                        kCFNumberIntType, &value);
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
}

static bool device_property_int(IOHIDDeviceRef device, CFStringRef key,
                                int *value)
{
    CFTypeRef property = IOHIDDeviceGetProperty(device, key);
    return property != NULL && CFGetTypeID(property) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)property, kCFNumberIntType, value);
}

static bool open_connection(ota_connection_t *connection, bool report_errors)
{
    memset(connection, 0, sizeof(*connection));
    connection->manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                              kIOHIDOptionsTypeNone);
    if (connection->manager == NULL) {
        if (report_errors) {
            fprintf(stderr, "Unable to create the macOS HID manager.\n");
        }
        return false;
    }

    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    dictionary_set_int(matching, CFSTR(kIOHIDVendorIDKey), VOICEOPS_USB_VID);
    dictionary_set_int(matching, CFSTR(kIOHIDProductIDKey), VOICEOPS_USB_PID);
    IOHIDManagerSetDeviceMatching(connection->manager, matching);
    CFRelease(matching);

    IOReturn result = IOHIDManagerOpen(connection->manager,
                                       kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        if (report_errors) {
            fprintf(stderr, "Unable to open the macOS HID manager (0x%08x).\n",
                    result);
        }
        CFRelease(connection->manager);
        connection->manager = NULL;
        return false;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(connection->manager);
    if (devices != NULL) {
        CFIndex count = CFSetGetCount(devices);
        IOHIDDeviceRef *values = calloc((size_t)count, sizeof(*values));
        if (values != NULL) {
            CFSetGetValues(devices, (const void **)values);
            for (CFIndex index = 0; index < count; ++index) {
                int usage_page = 0;
                int usage = 0;
                if (device_property_int(values[index],
                                        CFSTR(kIOHIDPrimaryUsagePageKey),
                                        &usage_page) &&
                    device_property_int(values[index],
                                        CFSTR(kIOHIDPrimaryUsageKey), &usage) &&
                    usage_page == VOICEOPS_OTA_VENDOR_USAGE_PAGE &&
                    usage == VOICEOPS_OTA_VENDOR_USAGE) {
                    connection->device = values[index];
                    CFRetain(connection->device);
                    break;
                }
            }
            free(values);
        }
        CFRelease(devices);
    }

    if (connection->device == NULL) {
        if (report_errors) {
            fprintf(stderr,
                    "MLX Voice Mic USB OTA interface was not found.\n"
                    "The OTA-capable firmware must be installed once through the "
                    "ESP32-S3 ROM downloader; no extra wiring or Wi-Fi is used.\n");
        }
        IOHIDManagerClose(connection->manager, kIOHIDOptionsTypeNone);
        CFRelease(connection->manager);
        connection->manager = NULL;
        return false;
    }

    result = IOHIDDeviceOpen(connection->device, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        if (report_errors) {
            fprintf(stderr, "Unable to open the firmware update interface "
                            "(0x%08x).\n", result);
        }
        CFRelease(connection->device);
        connection->device = NULL;
        IOHIDManagerClose(connection->manager, kIOHIDOptionsTypeNone);
        CFRelease(connection->manager);
        connection->manager = NULL;
        return false;
    }
    return true;
}

static void close_connection(ota_connection_t *connection)
{
    if (connection->device != NULL) {
        IOHIDDeviceClose(connection->device, kIOHIDOptionsTypeNone);
        CFRelease(connection->device);
    }
    if (connection->manager != NULL) {
        IOHIDManagerClose(connection->manager, kIOHIDOptionsTypeNone);
        CFRelease(connection->manager);
    }
    memset(connection, 0, sizeof(*connection));
}

static bool read_response(IOHIDDeviceRef device,
                          voiceops_ota_response_t *response)
{
    CFIndex length = sizeof(*response);
    memset(response, 0, sizeof(*response));
    IOReturn result = IOHIDDeviceGetReport(
        device, kIOHIDReportTypeFeature, 0, (uint8_t *)response, &length);
    return result == kIOReturnSuccess && length == sizeof(*response) &&
           response->magic == VOICEOPS_OTA_MAGIC &&
           response->version == VOICEOPS_OTA_PROTOCOL_VERSION;
}

static bool send_and_wait(IOHIDDeviceRef device,
                          const voiceops_ota_request_t *request,
                          unsigned timeout_ms,
                          voiceops_ota_response_t *response)
{
    IOReturn result = IOHIDDeviceSetReport(
        device, kIOHIDReportTypeFeature, 0, (const uint8_t *)request,
        sizeof(*request));
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "USB request %u failed (0x%08x).\n",
                request->command, result);
        return false;
    }

    const uint64_t deadline = monotonic_milliseconds() + timeout_ms;
    do {
        if (read_response(device, response) &&
            response->sequence == request->sequence &&
            response->last_command == request->command) {
            if (response->status != VOICEOPS_OTA_STATUS_OK) {
                fprintf(stderr, "Device rejected request %u: %s (%" PRIu32
                                "); sequence=%" PRIu32 ", offset=%" PRIu32
                                ", length=%u, device_next=%" PRIu32
                                ", total=%" PRIu32 ".\n",
                        request->command, status_name(response->status),
                        response->status, request->sequence, request->offset,
                        request->payload_length, response->next_offset,
                        response->total_size);
                return false;
            }
            return true;
        }
        sleep_milliseconds(2);
    } while (monotonic_milliseconds() < deadline);

    fprintf(stderr, "Timed out waiting for request %u sequence %" PRIu32
                    ".\n", request->command, request->sequence);
    return false;
}

static bool load_image(const char *path, uint8_t **bytes, uint32_t *size,
                       uint32_t *crc)
{
    *bytes = NULL;
    *size = 0;
    *crc = 0;

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        fprintf(stderr, "Unable to open %s: %s\n", path, strerror(errno));
        return false;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return false;
    }
    long file_size = ftell(file);
    if (file_size <= 0 || (uint64_t)file_size > UINT32_MAX ||
        fseek(file, 0, SEEK_SET) != 0) {
        fprintf(stderr, "Invalid or oversized firmware image: %s\n", path);
        fclose(file);
        return false;
    }

    uint8_t *data = malloc((size_t)file_size);
    if (data == NULL || fread(data, 1, (size_t)file_size, file) !=
                            (size_t)file_size) {
        fprintf(stderr, "Unable to read firmware image: %s\n", path);
        free(data);
        fclose(file);
        return false;
    }
    fclose(file);

    if (data[0] != 0xe9) {
        fprintf(stderr, "%s is not an ESP32 application image.\n", path);
        free(data);
        return false;
    }

    *bytes = data;
    *size = (uint32_t)file_size;
    *crc = voiceops_ota_crc32_update(UINT32_C(0xffffffff), data,
                                     (size_t)file_size) ^ UINT32_C(0xffffffff);
    return true;
}

static bool send_local_time(IOHIDDeviceRef device)
{
    const time_t now = time(NULL);
    struct tm local_time;
    if (now == (time_t)-1 || localtime_r(&now, &local_time) == NULL ||
        local_time.tm_year < 100 || local_time.tm_year > 199) {
        fprintf(stderr, "The Mac local time is outside the RTC range 2000-2099.\n");
        return false;
    }

    const voiceops_clock_payload_t payload = {
        .year_since_2000 = (uint8_t)(local_time.tm_year - 100),
        .month = (uint8_t)(local_time.tm_mon + 1),
        .day = (uint8_t)local_time.tm_mday,
        .weekday = (uint8_t)local_time.tm_wday,
        .hour = (uint8_t)local_time.tm_hour,
        .minute = (uint8_t)local_time.tm_min,
        .second = (uint8_t)local_time.tm_sec,
    };
    voiceops_ota_request_t request = {
        .magic = VOICEOPS_OTA_MAGIC,
        .version = VOICEOPS_OTA_PROTOCOL_VERSION,
        .command = VOICEOPS_OTA_COMMAND_SYNC_CLOCK,
        .payload_length = sizeof(payload),
        .sequence = 1,
    };
    memcpy(request.payload, &payload, sizeof(payload));
    voiceops_ota_response_t response;
    if (!send_and_wait(device, &request, 3000, &response)) {
        return false;
    }
    printf("RTC synchronized to Mac local time: %04d-%02d-%02d %02d:%02d:%02d.\n",
           local_time.tm_year + 1900, local_time.tm_mon + 1,
           local_time.tm_mday, local_time.tm_hour, local_time.tm_min,
           local_time.tm_sec);
    return true;
}

static void print_response(const voiceops_ota_response_t *response)
{
    char version[sizeof(response->running_version) + 1];
    memcpy(version, response->running_version,
           sizeof(response->running_version));
    version[sizeof(response->running_version)] = '\0';
    printf("state: %s\n", state_name(response->state));
    printf("firmware: %s\n", version[0] != '\0' ? version : "unknown");
    printf("running slot: 0x%02" PRIx32 "\n",
           response->running_partition_subtype);
    printf("target slot: 0x%02" PRIx32 "\n",
           response->target_partition_subtype);
    printf("progress: %" PRIu32 "/%" PRIu32 " bytes\n",
           response->next_offset, response->total_size);
    printf("last status: %s\n", status_name(response->status));
    printf("input: sources=0x%02x touch=%u/%u pwr=%u/%u armed=%u\n",
           response->reserved[0], response->reserved[1],
           response->reserved[2], response->reserved[3],
           response->reserved[4], response->reserved[5]);
    if (response->reserved[6] != 0) {
        printf("clock: %02u:%02u local\n", response->reserved[7],
               response->reserved[8]);
    } else {
        printf("clock: unsynchronized\n");
    }
}

static int run_status(void)
{
    ota_connection_t connection;
    if (!open_connection(&connection, true)) {
        return 1;
    }
    voiceops_ota_response_t response;
    bool success = read_response(connection.device, &response);
    if (success) {
        print_response(&response);
    } else {
        fprintf(stderr, "The device returned an invalid OTA status report.\n");
    }
    close_connection(&connection);
    return success ? 0 : 1;
}

static int run_sync_time(void)
{
    ota_connection_t connection;
    if (!open_connection(&connection, true)) {
        return 1;
    }
    const bool success = send_local_time(connection.device);
    close_connection(&connection);
    return success ? 0 : 1;
}

static int run_update(const char *path)
{
    uint8_t *image = NULL;
    uint32_t image_size = 0;
    uint32_t image_crc = 0;
    if (!load_image(path, &image, &image_size, &image_crc)) {
        return 1;
    }
    printf("Image: %s (%" PRIu32 " bytes, CRC32 %08" PRIx32 ")\n",
           path, image_size, image_crc);

    ota_connection_t connection;
    if (!open_connection(&connection, true)) {
        free(image);
        return 1;
    }

    uint32_t sequence = 1;
    voiceops_ota_request_t request = {
        .magic = VOICEOPS_OTA_MAGIC,
        .version = VOICEOPS_OTA_PROTOCOL_VERSION,
        .command = VOICEOPS_OTA_COMMAND_BEGIN,
        .sequence = sequence++,
        .value = image_size,
    };
    voiceops_ota_response_t response;
    bool success = send_and_wait(connection.device, &request, 15000,
                                 &response);
    if (success && response.total_size != image_size) {
        fprintf(stderr, "Device reported an unexpected image size.\n");
        success = false;
    }

    uint32_t offset = 0;
    unsigned last_percentage = 101;
    while (success && offset < image_size) {
        const uint16_t chunk_size = next_chunk_size(image_size, offset);
        memset(&request, 0, sizeof(request));
        request.magic = VOICEOPS_OTA_MAGIC;
        request.version = VOICEOPS_OTA_PROTOCOL_VERSION;
        request.command = VOICEOPS_OTA_COMMAND_DATA;
        request.payload_length = chunk_size;
        request.sequence = sequence++;
        request.offset = offset;
        memcpy(request.payload, image + offset, chunk_size);
        success = send_and_wait(connection.device, &request, 3000, &response);
        if (success && response.next_offset != offset + chunk_size) {
            fprintf(stderr, "Device acknowledged offset %" PRIu32
                            ", expected %" PRIu32 ".\n",
                    response.next_offset, offset + chunk_size);
            success = false;
            break;
        }
        offset += chunk_size;
        unsigned percentage = (unsigned)((uint64_t)offset * 100U / image_size);
        if (percentage != last_percentage) {
            printf("\rWriting: %3u%%", percentage);
            fflush(stdout);
            last_percentage = percentage;
        }
    }
    if (offset > 0) {
        printf("\n");
    }

    if (success) {
        memset(&request, 0, sizeof(request));
        request.magic = VOICEOPS_OTA_MAGIC;
        request.version = VOICEOPS_OTA_PROTOCOL_VERSION;
        request.command = VOICEOPS_OTA_COMMAND_FINISH;
        request.sequence = sequence++;
        request.offset = image_size;
        request.value = image_crc;
        success = send_and_wait(connection.device, &request, 15000,
                                &response);
        if (success && response.state != VOICEOPS_OTA_STATE_READY_TO_REBOOT) {
            fprintf(stderr, "Image was written but the boot slot was not "
                            "committed.\n");
            success = false;
        }
    }

    if (success) {
        memset(&request, 0, sizeof(request));
        request.magic = VOICEOPS_OTA_MAGIC;
        request.version = VOICEOPS_OTA_PROTOCOL_VERSION;
        request.command = VOICEOPS_OTA_COMMAND_REBOOT;
        request.sequence = sequence++;
        success = send_and_wait(connection.device, &request, 2000, &response);
    }

    if (!success) {
        memset(&request, 0, sizeof(request));
        request.magic = VOICEOPS_OTA_MAGIC;
        request.version = VOICEOPS_OTA_PROTOCOL_VERSION;
        request.command = VOICEOPS_OTA_COMMAND_ABORT;
        request.sequence = sequence++;
        (void)send_and_wait(connection.device, &request, 1000, &response);
    } else {
        printf("Update committed. The microphone is restarting automatically; "
               "no button press is required.\n");
    }

    close_connection(&connection);
    free(image);

    if (success) {
        bool clock_synced = false;
        for (unsigned attempt = 0; attempt < 20 && !clock_synced; ++attempt) {
            sleep_milliseconds(500);
            ota_connection_t restarted;
            if (open_connection(&restarted, false)) {
                clock_synced = send_local_time(restarted.device);
                close_connection(&restarted);
            }
        }
        if (!clock_synced) {
            fprintf(stderr, "Firmware update succeeded, but automatic RTC sync "
                            "did not complete. Run `voiceops-ota sync-time` "
                            "after the board reconnects.\n");
        }
    }
    return success ? 0 : 1;
}

static int run_verify(const char *path)
{
    uint8_t *image = NULL;
    uint32_t size = 0;
    uint32_t crc = 0;
    bool success = load_image(path, &image, &size, &crc);
    if (success) {
        printf("Valid ESP application image: %" PRIu32
               " bytes, CRC32 %08" PRIx32 "\n", size, crc);
    }
    free(image);
    return success ? 0 : 1;
}

static int run_self_test(void)
{
    static const uint8_t input[] = "123456789";
    uint32_t crc = voiceops_ota_crc32_update(
        UINT32_C(0xffffffff), input, sizeof(input) - 1) ^ UINT32_C(0xffffffff);
    if (crc != UINT32_C(0xcbf43926)) {
        fprintf(stderr, "CRC32 self-test failed: %08" PRIx32 "\n", crc);
        return 1;
    }
    if (next_chunk_size(666496, 11136) != VOICEOPS_OTA_PAYLOAD_SIZE ||
        next_chunk_size(100, 80) != 20) {
        fprintf(stderr, "OTA chunk-size boundary self-test failed.\n");
        return 1;
    }
    printf("Protocol self-test passed (64-byte reports, CRC32 %08" PRIx32
           ", chunk boundary).\n", crc);
    return 0;
}

static void print_usage(const char *program)
{
    fprintf(stderr,
            "Usage:\n"
            "  %s status\n"
            "  %s sync-time\n"
            "  %s update PATH_TO_MLX_VOICE_MIC.BIN\n"
            "  %s verify PATH_TO_MLX_VOICE_MIC.BIN\n"
            "  %s self-test\n",
            program, program, program, program, program);
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "status") == 0) {
        return run_status();
    }
    if (argc == 2 && strcmp(argv[1], "sync-time") == 0) {
        return run_sync_time();
    }
    if (argc == 3 && strcmp(argv[1], "update") == 0) {
        return run_update(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "verify") == 0) {
        return run_verify(argv[2]);
    }
    if (argc == 2 && strcmp(argv[1], "self-test") == 0) {
        return run_self_test();
    }
    print_usage(argv[0]);
    return 2;
}
