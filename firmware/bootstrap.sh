#!/usr/bin/env bash
set -euo pipefail

FIRMWARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$FIRMWARE_DIR/dependencies.sh"

command -v git >/dev/null || { echo "Install Git before fetching firmware dependencies." >&2; exit 1; }

fetch_revision() {
  local url="$1" revision="$2" destination="$3"
  if [ ! -d "$destination/.git" ]; then
    if [ -d "$destination" ] && [ -n "$(ls -A "$destination")" ]; then
      echo "Refusing to replace existing files in $destination." >&2
      exit 1
    fi
    mkdir -p "$destination"
    git -C "$destination" init -q
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach -q FETCH_HEAD
  fi
  if [ "$(git -C "$destination" rev-parse HEAD)" != "$revision" ]; then
    echo "$destination is at a different revision; move it aside and rerun bootstrap.sh." >&2
    exit 1
  fi
  if [ -n "$(git -C "$destination" status --porcelain --untracked-files=no)" ]; then
    echo "$destination has modified dependency files; move it aside to use the pinned sources." >&2
    exit 1
  fi
}

fetch_revision https://github.com/hathach/tinyusb.git "$TINYUSB_REV" "$FIRMWARE_DIR/deps/tinyusb"
fetch_revision https://github.com/raspberrypi/pico-sdk.git "$PICO_SDK_REV" "$FIRMWARE_DIR/deps/pico-sdk"
fetch_revision https://github.com/lwip-tcpip/lwip.git "$LWIP_REV" "$FIRMWARE_DIR/deps/tinyusb/lib/lwip"
fetch_revision https://github.com/hathach/linkermap.git "$LINKERMAP_REV" "$FIRMWARE_DIR/deps/tinyusb/tools/linkermap"

echo "Firmware dependencies ready."
