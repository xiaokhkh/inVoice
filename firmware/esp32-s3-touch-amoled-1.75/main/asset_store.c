#include "asset_store.h"

#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include "esp_log.h"
#include "esp_partition.h"

#define ASSET_PARTITION_LABEL "assets"
#define ASSET_HEADER_SIZE 12U
#define ASSET_NAME_SIZE 32U
#define ASSET_MARKER_SIZE 2U

static const char *TAG = "asset_store";

typedef struct __attribute__((packed)) {
    char name[ASSET_NAME_SIZE];
    uint32_t size;
    uint32_t offset;
    uint16_t width;
    uint16_t height;
} asset_entry_t;

static const esp_partition_t *s_partition;
static const uint8_t *s_root;
static esp_partition_mmap_handle_t s_mmap_handle;
static uint32_t s_file_count;

static uint32_t checksum16(const uint8_t *data, size_t length)
{
    uint32_t checksum = 0;
    for (size_t i = 0; i < length; ++i) {
        checksum += data[i];
    }
    return checksum & 0xffffU;
}

esp_err_t asset_store_init(void)
{
    if (s_root != NULL) {
        return ESP_OK;
    }

    s_partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_ANY, ESP_PARTITION_SUBTYPE_ANY, ASSET_PARTITION_LABEL);
    if (s_partition == NULL) {
        ESP_LOGE(TAG, "assets partition not found");
        return ESP_ERR_NOT_FOUND;
    }

    esp_err_t ret = esp_partition_mmap(
        s_partition, 0, s_partition->size, ESP_PARTITION_MMAP_DATA,
        (const void **)&s_root, &s_mmap_handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "failed to map assets: %s", esp_err_to_name(ret));
        return ret;
    }

    const uint32_t stored_checksum = *(const uint32_t *)(s_root + 4);
    const uint32_t stored_length = *(const uint32_t *)(s_root + 8);
    s_file_count = *(const uint32_t *)s_root;

    const size_t table_size = (size_t)s_file_count * sizeof(asset_entry_t);
    if (s_file_count == 0 || s_file_count > 128 ||
        ASSET_HEADER_SIZE + table_size > s_partition->size ||
        stored_length > s_partition->size - ASSET_HEADER_SIZE) {
        ESP_LOGE(TAG, "invalid assets header");
        return ESP_ERR_INVALID_SIZE;
    }

    const uint32_t actual_checksum = checksum16(s_root + ASSET_HEADER_SIZE, stored_length);
    if (actual_checksum != stored_checksum) {
        ESP_LOGE(TAG, "assets checksum mismatch: expected=%04" PRIx32 " actual=%04" PRIx32,
                 stored_checksum, actual_checksum);
        return ESP_ERR_INVALID_CRC;
    }

    ESP_LOGI(TAG, "mounted %" PRIu32 " preserved assets", s_file_count);
    return ESP_OK;
}

esp_err_t asset_store_get(const char *name, const uint8_t **data, size_t *size)
{
    if (name == NULL || data == NULL || size == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    if (s_root == NULL) {
        esp_err_t ret = asset_store_init();
        if (ret != ESP_OK) {
            return ret;
        }
    }

    const size_t data_start = ASSET_HEADER_SIZE + (size_t)s_file_count * sizeof(asset_entry_t);
    for (uint32_t i = 0; i < s_file_count; ++i) {
        const asset_entry_t *entry = (const asset_entry_t *)(
            s_root + ASSET_HEADER_SIZE + (size_t)i * sizeof(asset_entry_t));
        if (strncmp(entry->name, name, ASSET_NAME_SIZE) != 0) {
            continue;
        }

        const size_t marker_offset = data_start + entry->offset;
        const size_t end = marker_offset + ASSET_MARKER_SIZE + entry->size;
        if (end > s_partition->size || s_root[marker_offset] != 'Z' ||
            s_root[marker_offset + 1] != 'Z') {
            ESP_LOGE(TAG, "invalid asset payload: %s", name);
            return ESP_ERR_INVALID_RESPONSE;
        }

        *data = s_root + marker_offset + ASSET_MARKER_SIZE;
        *size = entry->size;
        return ESP_OK;
    }

    ESP_LOGE(TAG, "asset not found: %s", name);
    return ESP_ERR_NOT_FOUND;
}
