#include "audio_input.h"

#include <stdatomic.h>
#include <string.h>
#include "bsp/esp-bsp.h"
#include "driver/i2c_master.h"
#include "driver/i2s_std.h"
#include "driver/i2s_tdm.h"
#include "esp_check.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#define PMIC_ADDRESS 0x34
#define PMIC_COMMON_CONFIG_REG 0x10
#define PMIC_PWRON_SHUTDOWN_BIT (1U << 2)
#define PMIC_ALDO_ENABLE_REG 0x90
#define PMIC_ALDO1_VOLTAGE_REG 0x92
#define PMIC_ALDO1_3300MV 0x1c
#define MIC_GAIN_DB 36.0f

static const char *TAG = "audio_input";
static i2s_chan_handle_t s_tx_handle;
static i2s_chan_handle_t s_rx_handle;
static const audio_codec_data_if_t *s_data_if;
static const audio_codec_ctrl_if_t *s_input_ctrl_if;
static const audio_codec_if_t *s_input_codec_if;
static esp_codec_dev_handle_t s_input_device;
static SemaphoreHandle_t s_read_mutex;
static atomic_bool s_muted;

static esp_err_t pmic_write(i2c_master_dev_handle_t device, uint8_t reg, uint8_t value)
{
    const uint8_t command[] = {reg, value};
    return i2c_master_transmit(device, command, sizeof(command), 1000);
}

static esp_err_t pmic_read(i2c_master_dev_handle_t device, uint8_t reg, uint8_t *value)
{
    return i2c_master_transmit_receive(device, &reg, 1, value, 1, 1000);
}

esp_err_t audio_power_init(void)
{
    ESP_RETURN_ON_ERROR(bsp_i2c_init(), TAG, "I2C init failed");

    i2c_device_config_t config = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = PMIC_ADDRESS,
        .scl_speed_hz = 400000,
    };
    i2c_master_dev_handle_t pmic = NULL;
    ESP_RETURN_ON_ERROR(
        i2c_master_bus_add_device(bsp_i2c_get_handle(), &config, &pmic), TAG,
        "PMIC attach failed");

    uint8_t enables = 0;
    uint8_t common_config = 0;
    esp_err_t ret = pmic_write(pmic, PMIC_ALDO1_VOLTAGE_REG, PMIC_ALDO1_3300MV);
    if (ret == ESP_OK) {
        ret = pmic_read(pmic, PMIC_ALDO_ENABLE_REG, &enables);
    }
    if (ret == ESP_OK) {
        ret = pmic_write(pmic, PMIC_ALDO_ENABLE_REG, enables | 0x01U);
    }
    if (ret == ESP_OK) {
        ret = pmic_read(pmic, PMIC_COMMON_CONFIG_REG, &common_config);
    }
    if (ret == ESP_OK) {
        // PWR is a push-to-talk source in this firmware.  Prevent AXP2101 from
        // shutting the PMIC down while the user holds it through a long phrase.
        ret = pmic_write(pmic, PMIC_COMMON_CONFIG_REG,
                         common_config & ~PMIC_PWRON_SHUTDOWN_BIT);
    }
    i2c_master_bus_rm_device(pmic);
    ESP_RETURN_ON_ERROR(ret, TAG, "failed to enable microphone power");

    ESP_LOGI(TAG, "microphone power rail enabled; PWR long-press shutdown disabled");
    return ESP_OK;
}

static esp_err_t create_i2s_channels(void)
{
    i2s_chan_config_t channel_config = {
        .id = I2S_NUM_0,
        .role = I2S_ROLE_MASTER,
        .dma_desc_num = 6,
        .dma_frame_num = 240,
        .auto_clear_after_cb = true,
        .auto_clear_before_cb = false,
        .intr_priority = 0,
    };
    ESP_RETURN_ON_ERROR(
        i2s_new_channel(&channel_config, &s_tx_handle, &s_rx_handle), TAG,
        "I2S channel creation failed");

    const i2s_std_config_t tx_config = {
        .clk_cfg = {
            .sample_rate_hz = MLX_MIC_SAMPLE_RATE,
            .clk_src = I2S_CLK_SRC_DEFAULT,
            .ext_clk_freq_hz = 0,
            .mclk_multiple = I2S_MCLK_MULTIPLE_256,
        },
        .slot_cfg = {
            .data_bit_width = I2S_DATA_BIT_WIDTH_16BIT,
            .slot_bit_width = I2S_SLOT_BIT_WIDTH_AUTO,
            .slot_mode = I2S_SLOT_MODE_STEREO,
            .slot_mask = I2S_STD_SLOT_BOTH,
            .ws_width = I2S_DATA_BIT_WIDTH_16BIT,
            .ws_pol = false,
            .bit_shift = true,
            .left_align = true,
            .big_endian = false,
            .bit_order_lsb = false,
        },
        .gpio_cfg = {
            .mclk = BSP_I2S_MCLK,
            .bclk = BSP_I2S_SCLK,
            .ws = BSP_I2S_LCLK,
            .dout = BSP_I2S_DOUT,
            .din = I2S_GPIO_UNUSED,
        },
    };

    const i2s_tdm_config_t rx_config = {
        .clk_cfg = {
            .sample_rate_hz = MLX_MIC_SAMPLE_RATE,
            .clk_src = I2S_CLK_SRC_DEFAULT,
            .ext_clk_freq_hz = 0,
            .mclk_multiple = I2S_MCLK_MULTIPLE_256,
            .bclk_div = 8,
        },
        .slot_cfg = {
            .data_bit_width = I2S_DATA_BIT_WIDTH_16BIT,
            .slot_bit_width = I2S_SLOT_BIT_WIDTH_AUTO,
            .slot_mode = I2S_SLOT_MODE_STEREO,
            .slot_mask = (i2s_tdm_slot_mask_t)(
                I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3),
            .ws_width = I2S_TDM_AUTO_WS_WIDTH,
            .ws_pol = false,
            .bit_shift = true,
            .left_align = false,
            .big_endian = false,
            .bit_order_lsb = false,
            .skip_mask = false,
            .total_slot = I2S_TDM_AUTO_SLOT_NUM,
        },
        .gpio_cfg = {
            .mclk = BSP_I2S_MCLK,
            .bclk = BSP_I2S_SCLK,
            .ws = BSP_I2S_LCLK,
            .dout = I2S_GPIO_UNUSED,
            .din = BSP_I2S_DSIN,
        },
    };

    ESP_RETURN_ON_ERROR(
        i2s_channel_init_std_mode(s_tx_handle, &tx_config), TAG, "TX mode init failed");
    ESP_RETURN_ON_ERROR(
        i2s_channel_init_tdm_mode(s_rx_handle, &rx_config), TAG, "RX mode init failed");
    ESP_RETURN_ON_ERROR(i2s_channel_enable(s_tx_handle), TAG, "TX enable failed");
    ESP_RETURN_ON_ERROR(i2s_channel_enable(s_rx_handle), TAG, "RX enable failed");
    return ESP_OK;
}

esp_err_t audio_input_init(void)
{
    s_read_mutex = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_read_mutex != NULL, ESP_ERR_NO_MEM, TAG, "read mutex failed");
    ESP_RETURN_ON_ERROR(create_i2s_channels(), TAG, "I2S init failed");

    audio_codec_i2s_cfg_t data_config = {
        .port = I2S_NUM_0,
        .rx_handle = s_rx_handle,
        .tx_handle = s_tx_handle,
    };
    s_data_if = audio_codec_new_i2s_data(&data_config);
    ESP_RETURN_ON_FALSE(s_data_if != NULL, ESP_ERR_NO_MEM, TAG, "I2S data interface failed");

    audio_codec_i2c_cfg_t control_config = {
        .port = (i2c_port_t)BSP_I2C_NUM,
        .addr = ES7210_CODEC_DEFAULT_ADDR,
        .bus_handle = bsp_i2c_get_handle(),
    };
    s_input_ctrl_if = audio_codec_new_i2c_ctrl(&control_config);
    ESP_RETURN_ON_FALSE(s_input_ctrl_if != NULL, ESP_ERR_NO_MEM, TAG, "codec control failed");

    es7210_codec_cfg_t codec_config = {
        .ctrl_if = s_input_ctrl_if,
        .mic_selected = ES7210_SEL_MIC1 | ES7210_SEL_MIC2 | ES7210_SEL_MIC3 | ES7210_SEL_MIC4,
    };
    s_input_codec_if = es7210_codec_new(&codec_config);
    ESP_RETURN_ON_FALSE(s_input_codec_if != NULL, ESP_ERR_NO_MEM, TAG, "ES7210 init failed");

    esp_codec_dev_cfg_t device_config = {
        .dev_type = ESP_CODEC_DEV_TYPE_IN,
        .codec_if = s_input_codec_if,
        .data_if = s_data_if,
    };
    s_input_device = esp_codec_dev_new(&device_config);
    ESP_RETURN_ON_FALSE(s_input_device != NULL, ESP_ERR_NO_MEM, TAG, "input device failed");

    esp_codec_dev_sample_info_t sample_info = {
        .bits_per_sample = 16,
        .channel = 4,
        .channel_mask = ESP_CODEC_DEV_MAKE_CHANNEL_MASK(0),
        .sample_rate = MLX_MIC_SAMPLE_RATE,
        .mclk_multiple = 0,
    };
    ESP_RETURN_ON_ERROR(
        esp_codec_dev_open(s_input_device, &sample_info), TAG, "microphone open failed");
    ESP_RETURN_ON_ERROR(
        esp_codec_dev_set_in_channel_gain(
            s_input_device, ESP_CODEC_DEV_MAKE_CHANNEL_MASK(0), MIC_GAIN_DB),
        TAG, "microphone gain failed");

    atomic_store(&s_muted, false);
    ESP_LOGI(TAG, "ES7210 microphone ready: %d Hz, mono, 16-bit", MLX_MIC_SAMPLE_RATE);
    return ESP_OK;
}

esp_err_t audio_input_read(uint8_t *buffer, size_t length, size_t *bytes_read)
{
    if (buffer == NULL || bytes_read == NULL || s_input_device == NULL) {
        return ESP_ERR_INVALID_ARG;
    }
    xSemaphoreTake(s_read_mutex, portMAX_DELAY);
    esp_err_t ret = esp_codec_dev_read(s_input_device, buffer, (int)length);
    xSemaphoreGive(s_read_mutex);
    if (ret != ESP_OK) {
        *bytes_read = 0;
        return ret;
    }
    *bytes_read = length;
    if (atomic_load(&s_muted)) {
        memset(buffer, 0, length);
    }
    return ESP_OK;
}

void audio_input_set_muted(bool muted)
{
    atomic_store(&s_muted, muted);
}

bool audio_input_is_muted(void)
{
    return atomic_load(&s_muted);
}
