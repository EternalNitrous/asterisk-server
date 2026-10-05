# Reconstruction tools

these are the helpers used while building the iOS port. Python tools use the
standard library; native probes need macOS and the Xcode command-line tools.
use **Python 3.10 or newer**.

## Client handshake

```bash
python3 tools/probe_chica_client.py PHONE_IP
```

opens TCP port 18711, checks the greeting, sends `ack`, then closes with `bye`.
`ack` can run the server's original home / auto-sit behavior, and `bye` requests
a walk stop. run it with the robot stationary. `--port` changes the TCP port.

## Config probe

```bash
xcrun swiftc AsteriskServer/ChicaConfig.swift tools/config_probe.swift \
  -o /tmp/chica-config-probe
/tmp/chica-config-probe
```

checks the embedded config parser, geometry, modes, pin map, telemetry options,
and calibration fields. it doesn't connect to hardware.

## Gait bridge comparison

clone the [Android reconstruction](https://github.com/EternalNitrous/chica-server)
separately, then point the helper at that checkout:

```bash
python3 tools/compare_gait_bridge.py --android-root /path/to/chica-server
```

compiles both native probes into a temporary directory, compares 54 deterministic
frames across gaits 5–10, and removes the binaries when it finishes. the default
Android path is a neighboring `android-server` directory; `CHICA_ANDROID_ROOT`
also works. the app itself builds without an Android checkout.

to compare supplied original APK captures too:

```bash
python3 tools/compare_gait_bridge.py \
  --android-root /path/to/chica-server \
  --oracle-dir /path/to/oracle
```

`CHICA_ORACLE_DIR` can replace `--oracle-dir`. no private workspace location is
assumed. the expected JSONL names are listed in the script; captures aren't
bundled with this repository.

| exit | meaning |
| :--- | :------ |
| `0` | the requested comparisons passed |
| `1` | a comparison, output validation, or native build failed |
| `2` | invalid setup or missing requested capture files |

a local Android/iOS match establishes parity for the compared frames. it does
not establish full original-app exactness, command timing, overlapping workers,
or physical hardware behavior. the standalone `gait_bridge_probe.mm` emits
18 PWM values per supplied gait frame and can also be used directly.
