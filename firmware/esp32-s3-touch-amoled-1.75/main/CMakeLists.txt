idf_component_register(
    SRCS
        "main.c"
        "audio_input.c"
        "asset_store.c"
        "jam_ui.c"
        "gif/gifdec.c"
    INCLUDE_DIRS "." "gif"
    REQUIRES
        esp32_s3_touch_amoled_1_75
        usb_device_uac
        esp_partition
        esp_timer
        esp_driver_gpio
        esp_driver_i2c
        esp_driver_i2s
        esp_codec_dev
)
