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
| Other onboard devices | `QMI8658` IMU and `PCF85063` RTC; unused by this firmware |

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
toggle the inVoice clipboard-history panel. A single short display tap is a
no-op; double-tap the display within 650 ms to submit the current Codex input.
There is no always-listening voice
activation. There is no status text on screen. Only while a dictation control
is physically held, a speech-sensitive green circular meter runs
around the entire dial and the preserved Jam UI switches to `thinking.gif`.
Opening the microphone from the host or detecting speech cannot show the ring
or activate dictation by itself.
The firmware disables the AXP2101 PWR-key long-press shutdown action so a long
dictation cannot accidentally power the board off.

USB is exposed as a composite device: **MLX Voice Mic** (24 kHz, mono, 16-bit
PCM), a keyboard HID interface, and an independent vendor HID firmware-update
interface. F13 is the private push-to-talk signal, F14 is the dedicated
clipboard-panel signal, and F15 is the double-tap submit pulse. The updater
never emits keyboard reports. The matching `mlx-voiceops` build consumes these
controls and converts microphone audio to its 16 kHz ASR format.

For dock and hot-plug safety, the macOS host reads those controls only from the
board keyboard interface with VID/PID `0x303A:0x4002`; unrelated keyboards
cannot start a board recording. The firmware also republishes the complete
pressed/released state every 250 ms. Device removal forces an immediate release
on the host, while the periodic absolute report repairs a release lost during a
dock suspend/resume cycle.

Screen, PWR, and BOOT inputs additionally require 100 ms of continuous stable
state before a transition is accepted. After that filter, display touches under
250 ms remain tap candidates while a 250 ms hold starts PTT. This filters short
touch-controller and power-rail glitches without allowing speech to trigger PTT.

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

Protocol and recovery details are in
[`docs/ESP32_USB_OTA_PROTOCOL.md`](../../docs/ESP32_USB_OTA_PROTOCOL.md).

## Host integration

The macOS implementation lives in these files:

- `apps/macos/VoiceOps/Services/FnKeyMonitor.swift`: binds directly to the board
  keyboard VID/PID, aggregates hot-plug state per device, treats F13 as PTT and
  F14 as the clipboard-panel toggle, treats F15 as Codex submit, and forces
  release on removal.
- `apps/macos/VoiceOps/Services/AudioCaptureService.swift`: prefers
  `MLX Voice Mic` and converts its 24 kHz input for the 16 kHz recognizers.
- `apps/macos/VoiceOps/Services/FnSessionController.swift`: owns the recording
  Session and permits final delivery only once after release.
- `apps/macos/VoiceOps/Services/FocusInjector.swift`: verifies the target PID
  and publishes a single guarded Cmd+V or degrades to copy-only.

See `docs/ESP32_S3_TOUCH_AMOLED_1_75_ZH.md` for the complete Chinese handoff.
