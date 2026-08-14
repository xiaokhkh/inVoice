#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
firmware_dir="$project_root/firmware/esp32-s3-touch-amoled-1.75"
image_path="${1:-$firmware_dir/build/mlx_voice_mic.bin}"

if [[ ! -f "$image_path" ]]; then
    echo "Firmware image not found: $image_path" >&2
    echo "Build it with ESP-IDF first, or pass an image path." >&2
    exit 1
fi

make -C "$project_root/tools/voiceops-ota"
exec "$project_root/tools/voiceops-ota/build/voiceops-ota" update "$image_path"
