# Bundled firmware build

- File: [`chica_servo2040_usbnet.uf2`](chica_servo2040_usbnet.uf2)
- Built from this directory's [`source/`](source/) on 2026-10-04.
- Target: RP2040, TinyUSB board `raspberry_pi_pico` (the Servo2040 pin map is in the source).
- Configuration: `MinSizeRel`, C11 / C++17.
- Compiler: xPack GNU Arm Embedded GCC arm64 15.2.1, build 20251203.
- Build tools: CMake 3.30.2, Ninja 1.10.0.
- Size: 133,120 bytes.
- SHA-256: `8644456a5a2962fc9753fa67b34b1cab97cb326d649b2898c59c426279cf4026`.

| Dependency | Revision |
| :--- | :--- |
| TinyUSB | `11b4cf61efb2d59ebf358c4afdd2dfd4c614276e` |
| Pico SDK (2.2.0) | `a1438dff1d38bd9c65dbd693f0e5db4b9ae91779` |
| lwIP | `159e31b689577dbf69cf0683bbaffbd71fa5ee10` |
| picotool (2.2.0) | `a7eb3988f0645239185fadb4e25d8279478c2dbb` |
| linkermap | `8e1f440fa15c567aceb5aa0d14f6d18c329cc67f` |

The build completed with dependencies fetched into the ignored `deps/` directory.
The firmware was not flashed to a board during packaging. This records build
provenance, not hardware validation. Existing driver/compiler warnings remain.
