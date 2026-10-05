#!/usr/bin/env bash
set -euo pipefail

FIRMWARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FIRMWARE_DIR/dependencies.sh"
BUILD_DIR="$FIRMWARE_DIR/build"

for tool in git cmake ninja python3 arm-none-eabi-gcc arm-none-eabi-g++; do
  command -v "$tool" >/dev/null || { echo "Missing $tool. See firmware/README.md for build requirements." >&2; exit 1; }
done
specs="$(arm-none-eabi-gcc --print-file-name=nosys.specs)"
if [ ! -f "$specs" ]; then
  echo "The ARM toolchain needs newlib and nosys.specs. See firmware/README.md." >&2
  exit 1
fi

"$FIRMWARE_DIR/bootstrap.sh"
export PICO_SDK_PATH="$FIRMWARE_DIR/deps/pico-sdk"

# TinyUSB invokes `python`; use the Python 3 selected by this shell.
mkdir -p "$BUILD_DIR/tools"
ln -sf "$(command -v python3)" "$BUILD_DIR/tools/python"
export PATH="$BUILD_DIR/tools:$PATH"

cmake -S "$FIRMWARE_DIR/source" -B "$BUILD_DIR" -G Ninja \
  -DBOARD=raspberry_pi_pico \
  -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DTINYUSB_PATH="$FIRMWARE_DIR/deps/tinyusb" \
  -DPICO_SDK_PATH="$PICO_SDK_PATH" \
  -DPICOTOOL_GIT_BRANCH="$PICOTOOL_REV"
cmake --build "$BUILD_DIR" --parallel

echo "Built: $BUILD_DIR/chica_servo2040_usbnet.uf2"
