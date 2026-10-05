# Servo2040 USB Ethernet firmware

the firmware used by AsteriskServer is bundled here, along with its source.
it gives the Servo2040 a USB Ethernet interface for iOS and a USB serial interface
for the Android server. both use the same servo and telemetry byte protocol.

## Flashing

1. download [`chica_servo2040_usbnet.uf2`](chica_servo2040_usbnet.uf2).
2. disconnect servo power. hold **BOOTSEL** on the Servo2040 while connecting it
   to your computer over USB.
3. copy the UF2 onto the **RPI-RP2** drive. the board reboots into the firmware.
4. connect the board to the iPhone with a USB data cable and open AsteriskServer.

the board listens at **`192.168.204.1:18712`**. its DHCP server assigns the phone
an address starting at **`192.168.204.2`**. the USB serial interface remains
available for Android.

## Source

[`source/`](source/) contains the USB descriptors, network and servo command
handling, configuration headers, and the drivers needed to build this firmware.
the code was copied from the workspace's Servo2040 USB Ethernet project; only
the CMake paths were changed to make this copy build independently.

TinyUSB, the Pico SDK, lwIP, and the linkermap build helper are fetched at the revisions in
[`dependencies.sh`](dependencies.sh). the Pico SDK fetches the pinned picotool
revision during configuration to generate the UF2. no sibling checkout is needed.

## Building

you'll need **Git**, **CMake 3.20 or newer**, **Ninja**, **Python 3**, a host C/C++
compiler, and an **Arm GNU bare-metal toolchain** with newlib (`arm-none-eabi-gcc`
and `arm-none-eabi-g++`). Xcode Command Line Tools provide the host compiler on
macOS. the bundled build uses xPack GNU Arm Embedded GCC **15.2.1**.

put the ARM toolchain's `bin` directory on your `PATH`, then run this from the
repository root:

```bash
./firmware/build.sh
```

the script fetches dependencies, configures CMake for RP2040, and builds
**`firmware/build/chica_servo2040_usbnet.uf2`**. the first build needs an internet
connection. downloaded dependencies and build outputs are ignored by Git.
rebuilding doesn't replace the bundled release file; copy the new UF2 into this
directory when preparing a release.

[`BUILD_INFO.md`](BUILD_INFO.md) records the bundled file's checksum and build
versions. the firmware build is separate from Xcode; flashing is done from your
computer.

## License

the original Servo2040 driver is MIT licensed; see [`source/LICENSE`](source/LICENSE).
its bundled and downloaded libraries retain their original licenses and notices;
see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
