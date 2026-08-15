# inVoice ESP32-S3 USB OTA protocol

The microphone updates over the same USB Type-C cable used for audio and
controls. It does not use Wi-Fi, a network service, or a separate 5-wire
connection. BOOT remains the runtime clipboard-panel control and is not an
update trigger.

## Flash layout

| Name | Offset | Size | Purpose |
| --- | ---: | ---: | --- |
| `otadata` | `0x00D000` | 8 KiB | Active/pending OTA slot metadata |
| `ota_0` | `0x010000` | 4032 KiB | Application slot A |
| `ota_1` | `0x400000` | 4032 KiB | Application slot B |
| `assets` | `0x800000` | 8 MiB | Preserved Xiaozhi/Jam resources |

The first installation writes the bootloader, partition table, initial OTA
metadata, and `ota_0`. It deliberately does not write or erase `assets`.
Subsequent updates write only the inactive application slot.

## USB interface

The composite USB device exposes three independent functions:

- UAC microphone: 24 kHz, mono, 16-bit PCM;
- keyboard HID: F13 push-to-talk, F14 clipboard panel, and standard Enter for a short-screen-tap Return;
- vendor HID: usage page `0xFF00`, usage `0x0001`, 64-byte feature reports.

The host binds keyboard controls to the same board VID/PID rather than treating
global F13/F14 events as trusted input. The standard Return is intentionally
left to macOS as an ordinary keyboard event. Keyboard reports carry absolute state
and are refreshed every 250 ms; host-side device removal clears all pressed
state. This keeps dock suspend/resume and hot unplug from leaving dictation
latched on.

The updater matches VID/PID `0x303A:0x4002` plus the vendor usage page. OTA
traffic therefore cannot be interpreted as a key press and does not share the
keyboard HID permission path.

## Transaction

Every command carries the `VOTA` magic, protocol version, monotonic sequence,
offset, value, and up to 44 data bytes. The host allows only one in-flight
command and waits for a response carrying the same sequence.

```text
BEGIN(total image size)
  -> erase/open inactive OTA slot
DATA(offset, up to 44 bytes) ...
  -> acknowledge exact next offset after every chunk
FINISH(total size, CRC32)
  -> compare CRC32
  -> esp_ota_end validates the ESP application image
  -> atomically select the new boot slot
REBOOT
  -> acknowledge, then restart after 500 ms
```

`ABORT` closes an incomplete write without changing the boot partition. The
bootloader rollback option is enabled; a newly selected image is marked valid
only after display, microphone, USB audio, and OTA initialization succeed.

## Host commands

From the repository root:

```bash
make -C tools/voiceops-ota test
tools/voiceops-ota/build/voiceops-ota status
./scripts/update_esp32_firmware.sh
```

The script defaults to
`firmware/esp32-s3-touch-amoled-1.75/build/mlx_voice_mic.bin`. It validates the
ESP image and CRC before opening the device, shows write progress, commits the
inactive slot, and reboots the board automatically. No button press is part of
this update path.
