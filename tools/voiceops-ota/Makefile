ROOT := ../..
PROTOCOL_DIR := $(ROOT)/firmware/esp32-s3-touch-amoled-1.75/components/usb_device_uac/include
BUILD_DIR := build
TARGET := $(BUILD_DIR)/voiceops-ota

.PHONY: all clean test

all: $(TARGET)

$(TARGET): main.c $(PROTOCOL_DIR)/voiceops_ota_protocol.h
	mkdir -p $(BUILD_DIR)
	clang -std=c11 -O2 -Wall -Wextra -Werror \
		-I$(PROTOCOL_DIR) \
		-framework CoreFoundation -framework IOKit \
		main.c -o $(TARGET)

test: $(TARGET)
	$(TARGET) self-test

clean:
	rm -f $(TARGET)
