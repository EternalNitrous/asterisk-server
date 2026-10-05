# Firmware source and library notices

These notices accompany both the bundled UF2 and its source. Existing copyright
headers are preserved. The iOS application's GPL license does not replace these
upstream licenses.

| Component | License | Notice |
| :--- | :--- | :--- |
| Original Servo2040 driver, Copyright (c) 2023 Eddie Carrera | MIT | [source/LICENSE](source/LICENSE) |
| Pimoroni drivers and Servo2040 support, Copyright (c) 2021 Pimoroni Ltd | MIT | [licenses/Pimoroni-MIT.txt](licenses/Pimoroni-MIT.txt) |
| Raspberry Pi SDK and PIO examples | BSD-3-Clause | [licenses/PicoSDK-BSD.txt](licenses/PicoSDK-BSD.txt) and source headers |
| TinyUSB, including Ha Thach's USB example files | MIT | [licenses/TinyUSB-MIT.txt](licenses/TinyUSB-MIT.txt) and source headers |
| lwIP | BSD-3-Clause | [licenses/lwIP-BSD.txt](licenses/lwIP-BSD.txt) |
| DHCP, DNS and RNDIS helpers by Sergey Fetisov | MIT | [licenses/networking-MIT.txt](licenses/networking-MIT.txt) |
| Pico SDK printf by Marco Paland | MIT | [licenses/printf-MIT.txt](licenses/printf-MIT.txt) |
| picotool (build tool) | BSD-3-Clause | [licenses/picotool-BSD.txt](licenses/picotool-BSD.txt) |
| linkermap (build tool) | MIT | [licenses/linkermap-MIT.txt](licenses/linkermap-MIT.txt) |
| Newlib and libgloss runtime | Various permissive licenses | [licenses/COPYING.NEWLIB](licenses/COPYING.NEWLIB), [licenses/COPYING.LIBGLOSS](licenses/COPYING.LIBGLOSS) |
| GCC runtime | GPL-3.0 with GCC Runtime Library Exception | [licenses/GCC-GPL3.txt](licenses/GCC-GPL3.txt), [licenses/GCC-RUNTIME.txt](licenses/GCC-RUNTIME.txt) |

Upstream projects:

- <https://github.com/pimoroni/pimoroni-pico>
- <https://github.com/raspberrypi/pico-sdk>
- <https://github.com/hathach/tinyusb>
- <https://github.com/lwip-tcpip/lwip>
- <https://github.com/raspberrypi/picotool>
- <https://github.com/hathach/linkermap>
- <https://github.com/xpack-dev-tools/arm-none-eabi-gcc-xpack>

Dependency source is retrieved by [bootstrap.sh](bootstrap.sh), with exact
revisions in [dependencies.sh](dependencies.sh). The complete copyright and
license headers remain in those checkouts.
