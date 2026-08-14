cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
# Only configure the application and its dependency graph. This keeps unrelated
# ESP-IDF components (Wi-Fi, MQTT, Bluetooth, etc.) out of this USB-only build.
idf_build_set_property(MINIMAL_BUILD ON)
project(mlx_voice_mic)
