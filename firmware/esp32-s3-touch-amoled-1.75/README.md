# MLX Voice Mic firmware

Dedicated USB Audio Class microphone firmware for the Waveshare
ESP32-S3-Touch-AMOLED-1.75. It keeps the existing Xiaozhi `assets` partition and
uses the preserved 384×384 Jam animations as the interaction UI.

## Hardware target

| Part | Model / specification |
| --- | --- |
| Tested board | Waveshare `ESP32-S3-Touch-AMOLED-1.75`, standard SKU `31261` |
| SoC | `ESP32-S3R8`, 8 MB PSRAM, external 16 MB Flash |
| Display | 1.75-inch 466×466 AMOLED, `CO5300` QSPI controller |
| Touch | `CST9217` I2C controller |
| Audio | Dual onboard microphones through `ES7210` |
| Power and I/O | `AXP2101` PMIC and `TCA9554` I/O expander |
| Other onboard devices | `PCF85063` RTC drives the circadian display; `QMI8658` IMU is unused |

Waveshare identifies the enclosure variant as SKU `31262` (`-B`) and the GPS
variant as SKU `31264` (`-G`). This project regression-tests only the standard
SKU `31261`. The similarly named `ESP32-S3-Touch-AMOLED-1.75C` is different
hardware and is not a supported target. See the
[official board documentation](https://docs.waveshare.com/ESP32-S3-Touch-AMOLED-1.75)
for the manufacturer specification.

## UI states

- `happy.gif`: USB connected
- `neutral.gif`: ready
- `thinking.gif`: microphone stream active
- `sleepy.gif`: disconnected or muted
- `sad.gif`: initialization/runtime error

Hold the display or the top PWR button to begin inVoice dictation; release to
finish and send. Press the top BOOT button while the firmware is running to
toggle the inVoice clipboard-history panel. A short display tap sends a
standard Return key to the current frontmost application.
There is no always-listening voice
activation. There is no status text on screen. Only while a dictation control
is physically held, a speech-sensitive green circular meter runs
around the entire dial and the preserved Jam UI switches to `thinking.gif`.
Opening the microphone from the host or detecting speech cannot show the ring
or activate dictation by itself.
The firmware disables the AXP2101 PWR-key long-press shutdown action so a long
dictation cannot accidentally power the board off.

The transparent Jam animation sits over a time-aware neutral background. Its
lightness and the AMOLED brightness interpolate continuously from the darkest
night setting (28%) to the brightest daylight setting (100%) and back, without
switching color themes. The board reads local time from its `PCF85063` RTC every
30 seconds, so the look continues without a host connection. Until the RTC has
a valid time, the UI uses the original daylight background at 100% brightness.

USB is exposed as a composite device: **MLX Voice Mic** (24 kHz, mono, 16-bit
PCM), a keyboard HID interface, and an independent vendor HID firmware-update
interface. F13 is the private push-to-talk signal, F14 is the dedicated
clipboard-panel signal, and USB HID Enter is the short-tap Return pulse. The
updater never emits keyboard reports. The matching `mlx-voiceops` build consumes
F13/F14 and converts microphone audio to its 16 kHz ASR format; Return remains a
normal keyboard event that works in any frontmost application.

For dock and hot-plug safety, the macOS host reads those controls only from the
board keyboard interface with VID/PID `0x303A:0x4002`; unrelated keyboards
cannot start a board recording. The firmware also republishes the complete
pressed/released state every 250 ms. Device removal forces an immediate release
on the host, while the periodic absolute report repairs a release lost during a
dock suspend/resume cycle.

Screen touches require 40 ms of continuous stable state so quick taps remain
detectable, while PWR and BOOT retain their 100 ms filter. Display touches under
250 ms send Return on release while a 250 ms hold starts PTT. Touch-controller
glitches shorter than 40 ms remain filtered out. Touch PTT follows the input
device's absolute state instead of object-level release events. After boot or a
USB reconnect, PWR must first report a stable released level before it is armed;
a dock or PMIC line held high therefore cannot latch dictation on startup.

## Important

The dual-slot partition table deliberately keeps `assets` at `0x800000` with
an 8 MB size. Normal firmware flashing must not erase the entire chip and must
not write that partition. A full Xiaozhi backup should be kept before flashing.

## Build

Use ESP-IDF 5.5.x and build from this directory:

```bash
idf.py set-target esp32s3
idf.py build
```

The application image is generated at `build/mlx_voice_mic.bin`. The project
defaults deliberately disable the ESP32-S3 USB Serial/JTAG console so the same
native USB pins can expose the UAC microphone and HID keyboard interfaces.

## One-time OTA installation without deleting Jam assets

No 5-wire adapter, Wi-Fi, or network setup is needed. The first installation
changes the partition table, so use the ESP32-S3 ROM downloader once over the
same USB Type-C cable. Hold BOOT while reconnecting USB, release it after the
ROM device appears, then run:

```bash
idf.py -p /dev/cu.usbmodemXXXX flash
```

This writes the bootloader, dual-slot partition table, initial OTA metadata,
and slot `ota_0`; it leaves the Jam `assets` partition untouched. Never run
`erase-flash`.

## Later updates: Type-C only, no button

After the one-time installation, leave the board running normally and execute:

```bash
./scripts/update_esp32_firmware.sh
```

The host validates the ESP image and CRC, writes the inactive OTA slot, asks the
board to validate and atomically select it, and restarts the microphone. No
BOOT/Fn/PWR/screen press is needed. BOOT continues to open the clipboard panel
during normal operation; it is not an OTA trigger.

After the board reconnects, the updater also synchronizes the RTC to the Mac's
local date and time. To resynchronize without installing firmware, run:

```bash
tools/voiceops-ota/build/voiceops-ota sync-time
```

Protocol and recovery details are in
[`docs/ESP32_USB_OTA_PROTOCOL.md`](../../docs/ESP32_USB_OTA_PROTOCOL.md).

## Host integration

The macOS implementation lives in these files:

- `apps/macos/VoiceOps/Services/FnKeyMonitor.swift`: binds directly to the board
  keyboard VID/PID, aggregates hot-plug state per device, treats F13 as PTT and
  F14 as the clipboard-panel toggle, and forces release on removal. It does not
  intercept the standard Return emitted by a short screen tap.
- `apps/macos/VoiceOps/Services/AudioCaptureService.swift`: prefers
  `MLX Voice Mic` and converts its 24 kHz input for the 16 kHz recognizers.
- `apps/macos/VoiceOps/Services/FnSessionController.swift`: owns the recording
  Session and permits final delivery only once after release.
- `apps/macos/VoiceOps/Services/FocusInjector.swift`: verifies the target PID
  and publishes a single guarded Cmd+V or degrades to copy-only.

See `docs/ESP32_S3_TOUCH_AMOLED_1_75_ZH.md` for the complete Chinese handoff.
