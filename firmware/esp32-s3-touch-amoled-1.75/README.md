# MLX Voice Mic firmware

Dedicated USB Audio Class microphone firmware for the Waveshare
ESP32-S3-Touch-AMOLED-1.75. It keeps the existing Xiaozhi `assets` partition and
uses the preserved 384×384 Jam animations as the interaction UI.

## UI states

- `happy.gif`: USB connected
- `neutral.gif`: ready
- `thinking.gif`: microphone stream active
- `sleepy.gif`: disconnected or muted
- `sad.gif`: initialization/runtime error

Hold the display or the top PWR button to begin VoiceOps dictation; release to
finish and send. Press the top BOOT button while the firmware is running to
toggle the VoiceOps clipboard-history panel. There is no always-listening voice
activation. There is no status text on screen. Only while a dictation control
is physically held, a speech-sensitive green circular meter runs
around the entire dial and the preserved Jam UI switches to `thinking.gif`.
Opening the microphone from the host or detecting speech cannot show the ring
or activate dictation by itself.
The firmware disables the AXP2101 PWR-key long-press shutdown action so a long
dictation cannot accidentally power the board off.

USB is exposed as a composite device: **MLX Voice Mic** (24 kHz, mono, 16-bit
PCM) plus a keyboard HID interface. F13 is the private push-to-talk signal and
F14 is the dedicated clipboard-panel signal. The matching `mlx-voiceops` build
consumes both keys and converts microphone audio to its 16 kHz ASR format.

## Important

The partition table deliberately keeps `assets` at `0x800000` with an 8 MB
size. Normal firmware flashing must not erase the entire chip and must not write
that partition. A full Xiaozhi backup should be kept before flashing.

## Build

Use ESP-IDF 5.5.x and build from this directory:

```bash
idf.py set-target esp32s3
idf.py build
```

The application image is generated at `build/mlx_voice_mic.bin`. The project
defaults deliberately disable the ESP32-S3 USB Serial/JTAG console so the same
native USB pins can expose the UAC microphone and HID keyboard interfaces.

## Flash without deleting Jam assets

Never run `erase-flash`. A normal project flash writes the bootloader,
partition table, and application but leaves the `assets` partition intact:

```bash
idf.py -p /dev/cu.usbmodemXXXX flash
```

For an application-only update:

```bash
python3 -m esptool --chip esp32s3 \
  --port /dev/cu.usbmodemXXXX \
  --before no-reset --after watchdog-reset \
  write-flash 0x10000 build/mlx_voice_mic.bin
```

When the microphone firmware is already running, it exposes only USB Audio and
HID, not a serial port. Hold BOOT while reconnecting USB to enter the ROM
download mode, then release BOOT before flashing.

## Host integration

The macOS implementation lives in these files:

- `apps/macos/VoiceOps/Services/FnKeyMonitor.swift`: treats board F13 as PTT and
  F14 as the clipboard-panel toggle.
- `apps/macos/VoiceOps/Services/AudioCaptureService.swift`: prefers
  `MLX Voice Mic` and converts its 24 kHz input for the 16 kHz recognizers.
- `apps/macos/VoiceOps/Services/FnSessionController.swift`: owns the recording
  Session and permits final delivery only once after release.
- `apps/macos/VoiceOps/Services/FocusInjector.swift`: verifies the target PID
  and publishes a single guarded Cmd+V or degrades to copy-only.

See `docs/ESP32_S3_TOUCH_AMOLED_1_75_ZH.md` for the complete Chinese handoff.
