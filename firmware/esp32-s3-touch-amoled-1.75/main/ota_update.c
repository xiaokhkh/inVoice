#include "ota_update.h"

#include <stdbool.h>
#include <inttypes.h>
#include <string.h>

#include "esp_app_desc.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "voiceops_ota_protocol.h"

static const char *TAG = "usb_ota";

typedef struct {
    esp_ota_handle_t handle;
    const esp_partition_t *target;
    uint32_t total_size;
    uint32_t next_offset;
    uint32_t crc;
    bool active;
} ota_session_t;

static QueueHandle_t s_request_queue;
static portMUX_TYPE s_status_lock = portMUX_INITIALIZER_UNLOCKED;
static voiceops_ota_response_t s_status;

static void copy_status(voiceops_ota_response_t *destination)
{
    portENTER_CRITICAL(&s_status_lock);
    *destination = s_status;
    portEXIT_CRITICAL(&s_status_lock);
}

static void publish_status(uint8_t state, uint8_t command, uint32_t status,
                           uint32_t sequence, uint32_t next_offset,
                           uint32_t total_size, uint32_t target_subtype)
{
    portENTER_CRITICAL(&s_status_lock);
    s_status.state = state;
    s_status.last_command = command;
    s_status.status = status;
    s_status.sequence = sequence;
    s_status.next_offset = next_offset;
    s_status.total_size = total_size;
    s_status.target_partition_subtype = target_subtype;
    portEXIT_CRITICAL(&s_status_lock);
}

static void abort_session(ota_session_t *session)
{
    if (session->active) {
        esp_ota_abort(session->handle);
    }
    memset(session, 0, sizeof(*session));
}

static void delayed_restart_task(void *context)
{
    (void)context;
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
}

static void reject_request(const voiceops_ota_request_t *request,
                           voiceops_ota_status_t status,
                           const ota_session_t *session)
{
    publish_status(VOICEOPS_OTA_STATE_ERROR, request->command, status,
                   request->sequence, session->next_offset,
                   session->total_size,
                   session->target != NULL ? session->target->subtype : 0xffU);
}

static void process_request(const voiceops_ota_request_t *request,
                            ota_session_t *session)
{
    if (request->magic != VOICEOPS_OTA_MAGIC) {
        reject_request(request, VOICEOPS_OTA_STATUS_BAD_MAGIC, session);
        return;
    }
    if (request->version != VOICEOPS_OTA_PROTOCOL_VERSION) {
        reject_request(request, VOICEOPS_OTA_STATUS_BAD_VERSION, session);
        return;
    }
    if (request->payload_length > VOICEOPS_OTA_PAYLOAD_SIZE) {
        reject_request(request, VOICEOPS_OTA_STATUS_BAD_LENGTH, session);
        return;
    }

    switch ((voiceops_ota_command_t)request->command) {
    case VOICEOPS_OTA_COMMAND_STATUS: {
        voiceops_ota_response_t current;
        copy_status(&current);
        publish_status(session->active ? VOICEOPS_OTA_STATE_RECEIVING
                                       : current.state,
                       request->command, VOICEOPS_OTA_STATUS_OK,
                       request->sequence, session->next_offset,
                       session->total_size,
                       session->target != NULL ? session->target->subtype : 0xffU);
        return;
    }

    case VOICEOPS_OTA_COMMAND_BEGIN: {
        abort_session(session);
        if (request->payload_length != 0 || request->value == 0) {
            reject_request(request, VOICEOPS_OTA_STATUS_BAD_LENGTH, session);
            return;
        }

        const esp_partition_t *target = esp_ota_get_next_update_partition(NULL);
        if (target == NULL) {
            reject_request(request, VOICEOPS_OTA_STATUS_NO_PARTITION, session);
            return;
        }
        if (request->value > target->size) {
            session->target = target;
            reject_request(request, VOICEOPS_OTA_STATUS_IMAGE_TOO_LARGE, session);
            abort_session(session);
            return;
        }

        esp_ota_handle_t handle = 0;
        esp_err_t result = esp_ota_begin(target, request->value, &handle);
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "OTA begin failed: %s", esp_err_to_name(result));
            reject_request(request, VOICEOPS_OTA_STATUS_FLASH_ERROR, session);
            return;
        }

        session->handle = handle;
        session->target = target;
        session->total_size = request->value;
        session->next_offset = 0;
        session->crc = UINT32_C(0xffffffff);
        session->active = true;
        publish_status(VOICEOPS_OTA_STATE_RECEIVING, request->command,
                       VOICEOPS_OTA_STATUS_OK, request->sequence, 0,
                       session->total_size, target->subtype);
        ESP_LOGI(TAG, "Receiving %" PRIu32 " bytes into %s",
                 session->total_size, target->label);
        return;
    }

    case VOICEOPS_OTA_COMMAND_DATA: {
        if (!session->active) {
            reject_request(request, VOICEOPS_OTA_STATUS_BAD_STATE, session);
            return;
        }
        if (request->payload_length == 0 ||
            request->offset != session->next_offset ||
            request->offset + request->payload_length > session->total_size) {
            reject_request(request,
                           request->offset != session->next_offset
                               ? VOICEOPS_OTA_STATUS_OFFSET_MISMATCH
                               : VOICEOPS_OTA_STATUS_BAD_LENGTH,
                           session);
            return;
        }

        esp_err_t result = esp_ota_write(session->handle, request->payload,
                                         request->payload_length);
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "OTA write failed: %s", esp_err_to_name(result));
            abort_session(session);
            reject_request(request, VOICEOPS_OTA_STATUS_FLASH_ERROR, session);
            return;
        }
        session->crc = voiceops_ota_crc32_update(
            session->crc, request->payload, request->payload_length);
        session->next_offset += request->payload_length;
        publish_status(VOICEOPS_OTA_STATE_RECEIVING, request->command,
                       VOICEOPS_OTA_STATUS_OK, request->sequence,
                       session->next_offset, session->total_size,
                       session->target->subtype);
        return;
    }

    case VOICEOPS_OTA_COMMAND_FINISH: {
        if (!session->active) {
            reject_request(request, VOICEOPS_OTA_STATUS_BAD_STATE, session);
            return;
        }
        if (request->payload_length != 0 ||
            request->offset != session->total_size ||
            session->next_offset != session->total_size) {
            reject_request(request, VOICEOPS_OTA_STATUS_BAD_LENGTH, session);
            return;
        }

        const uint32_t calculated_crc = session->crc ^ UINT32_C(0xffffffff);
        if (request->value != calculated_crc) {
            ESP_LOGE(TAG, "CRC mismatch: host=%08" PRIx32 " device=%08" PRIx32,
                     request->value, calculated_crc);
            abort_session(session);
            reject_request(request, VOICEOPS_OTA_STATUS_CRC_MISMATCH, session);
            return;
        }

        const esp_partition_t *target = session->target;
        const uint32_t total_size = session->total_size;
        esp_err_t result = esp_ota_end(session->handle);
        session->active = false;
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "OTA image validation failed: %s", esp_err_to_name(result));
            memset(session, 0, sizeof(*session));
            reject_request(request, VOICEOPS_OTA_STATUS_INVALID_IMAGE, session);
            return;
        }
        result = esp_ota_set_boot_partition(target);
        if (result != ESP_OK) {
            ESP_LOGE(TAG, "Setting boot partition failed: %s", esp_err_to_name(result));
            memset(session, 0, sizeof(*session));
            reject_request(request, VOICEOPS_OTA_STATUS_FLASH_ERROR, session);
            return;
        }

        memset(session, 0, sizeof(*session));
        publish_status(VOICEOPS_OTA_STATE_READY_TO_REBOOT, request->command,
                       VOICEOPS_OTA_STATUS_OK, request->sequence, total_size,
                       total_size, target->subtype);
        ESP_LOGI(TAG, "OTA image verified; next boot partition is %s", target->label);
        return;
    }

    case VOICEOPS_OTA_COMMAND_ABORT:
        abort_session(session);
        publish_status(VOICEOPS_OTA_STATE_IDLE, request->command,
                       VOICEOPS_OTA_STATUS_OK, request->sequence, 0, 0, 0xffU);
        return;

    case VOICEOPS_OTA_COMMAND_REBOOT: {
        voiceops_ota_response_t current;
        copy_status(&current);
        if (session->active) {
            reject_request(request, VOICEOPS_OTA_STATUS_BAD_STATE, session);
            return;
        }
        publish_status(current.state, request->command, VOICEOPS_OTA_STATUS_OK,
                       request->sequence, current.next_offset,
                       current.total_size, current.target_partition_subtype);
        if (xTaskCreate(delayed_restart_task, "ota_restart", 2048, NULL, 10,
                        NULL) != pdPASS) {
            reject_request(request, VOICEOPS_OTA_STATUS_FLASH_ERROR, session);
        }
        return;
    }

    default:
        reject_request(request, VOICEOPS_OTA_STATUS_BAD_COMMAND, session);
        return;
    }
}

static void ota_worker_task(void *context)
{
    (void)context;
    ota_session_t session = {0};
    voiceops_ota_request_t request;
    for (;;) {
        if (xQueueReceive(s_request_queue, &request, portMAX_DELAY) == pdTRUE) {
            process_request(&request, &session);
        }
    }
}

esp_err_t ota_update_init(void)
{
    if (s_request_queue != NULL) {
        return ESP_OK;
    }

    memset(&s_status, 0, sizeof(s_status));
    s_status.magic = VOICEOPS_OTA_MAGIC;
    s_status.version = VOICEOPS_OTA_PROTOCOL_VERSION;
    s_status.state = VOICEOPS_OTA_STATE_IDLE;
    s_status.status = VOICEOPS_OTA_STATUS_OK;
    s_status.target_partition_subtype = 0xffU;

    const esp_partition_t *running = esp_ota_get_running_partition();
    if (running != NULL) {
        s_status.running_partition_subtype = running->subtype;
    }
    const esp_app_desc_t *description = esp_app_get_description();
    if (description != NULL) {
        strlcpy(s_status.running_version, description->version,
                sizeof(s_status.running_version));
    }

    s_request_queue = xQueueCreate(4, sizeof(voiceops_ota_request_t));
    if (s_request_queue == NULL) {
        return ESP_ERR_NO_MEM;
    }
    if (xTaskCreate(ota_worker_task, "usb_ota", 6144, NULL, 6, NULL) != pdPASS) {
        vQueueDelete(s_request_queue);
        s_request_queue = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

esp_err_t ota_update_confirm_running_image(void)
{
#if CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    esp_err_t result = esp_ota_get_state_partition(running, &state);
    if (result == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        result = esp_ota_mark_app_valid_cancel_rollback();
        if (result == ESP_OK) {
            ESP_LOGI(TAG, "Confirmed healthy OTA image in %s", running->label);
        }
        return result;
    }
    return result == ESP_ERR_NOT_SUPPORTED ? ESP_OK : result;
#else
    return ESP_OK;
#endif
}

uint16_t ota_update_get_report(uint8_t report_id, uint8_t report_type,
                               uint8_t *buffer, uint16_t requested_length,
                               void *context)
{
    (void)report_id;
    (void)context;
    if (buffer == NULL || report_type != 3 ||
        requested_length < sizeof(voiceops_ota_response_t)) {
        return 0;
    }
    voiceops_ota_response_t response;
    copy_status(&response);
    memcpy(buffer, &response, sizeof(response));
    return sizeof(response);
}

void ota_update_set_report(uint8_t report_id, uint8_t report_type,
                           const uint8_t *buffer, uint16_t buffer_size,
                           void *context)
{
    (void)report_id;
    (void)context;
    if (s_request_queue == NULL || buffer == NULL || report_type != 3 ||
        buffer_size != sizeof(voiceops_ota_request_t)) {
        return;
    }

    voiceops_ota_request_t request;
    memcpy(&request, buffer, sizeof(request));
    if (xQueueSend(s_request_queue, &request, 0) != pdTRUE) {
        ota_session_t empty = {0};
        reject_request(&request, VOICEOPS_OTA_STATUS_QUEUE_FULL, &empty);
    }
}
