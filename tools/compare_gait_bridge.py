#!/usr/bin/env python3
"""Compare iOS/Android gait pulses, optionally using supplied APK captures."""

from __future__ import annotations

import ast
import argparse
import importlib.util
import os
import pathlib
import re
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PULSES = re.compile(r"pulses=(\[.*\])")


def build(android: pathlib.Path, output: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    ios_probe = output / "ios_gait_probe"
    android_probe = output / "android_gait_probe"
    subprocess.run([
        "xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-framework", "Foundation",
        "-IAsteriskServer/Gait", "tools/gait_bridge_probe.mm",
        "AsteriskServer/Gait/ChicaGaitEngineBridge.mm",
        "AsteriskServer/Gait/apk_model.cpp",
        "AsteriskServer/Gait/pulse_conversion.cpp",
        "-o", str(ios_probe),
    ], cwd=ROOT, check=True)
    subprocess.run([
        "c++", "-std=c++17", "-Iapp/src/main/cpp", "tools/oracle/gait_probe.cpp",
        "app/src/main/cpp/apk_model.cpp", "app/src/main/cpp/pulse_conversion.cpp",
        "-o", str(android_probe),
    ], cwd=android, check=True)
    return ios_probe, android_probe


def compare(android_root: pathlib.Path, oracle_dir: pathlib.Path | None,
            ios_probe: pathlib.Path, android_probe: pathlib.Path) -> int:
    frames: list[tuple[int, int, int, int, float, float, float]] = []
    for gait in (5, 6, 7, 8, 9, 10):
        filtered = [0.0, 0.0, 0.0]
        target = [0.5, 0.0, 0.25]
        for index, dt in enumerate((0, 11, 10, 13, 10, 12, 11, 10)):
            filtered = [a + ((b - a) * 0.05) for a, b in zip(filtered, target)]
            frames.append((gait, 3, dt, 1, *filtered))
        filtered = [value * 0.9 for value in filtered]
        frames.append((gait, 3, 11, 0, *filtered))

    args: list[str] = []
    for frame in frames:
        args += ["--frame", ",".join(str(value) for value in frame)]

    android_text = subprocess.run([str(android_probe), *args], text=True, capture_output=True, check=True).stdout
    ios_text = subprocess.run([str(ios_probe), *args], text=True, capture_output=True, check=True).stdout
    expected = [ast.literal_eval(match.group(1)) for match in map(PULSES.search, android_text.splitlines()) if match]
    actual = [ast.literal_eval(line) for line in ios_text.splitlines() if line.startswith("[")]

    if not expected or any(len(frame) != 18 for frame in expected + actual):
        print("invalid or empty pulse output; expected 18 channels per frame")
        return 1
    if len(expected) != len(actual):
        print(f"frame count mismatch: android={len(expected)} ios={len(actual)}")
        return 1
    for index, (android, ios) in enumerate(zip(expected, actual)):
        if android != ios:
            diffs = [abs(left - right) for left, right in zip(android, ios)]
            print(f"frame {index} differs: max={max(diffs)} sum={sum(diffs)}")
            print(f"android={android}")
            print(f"ios    ={ios}")
            return 1
    print(f"Android/iOS bridge match: {len(actual)} deterministic frames across APK gaits 5 through 10")
    if oracle_dir is None:
        print("no --oracle-dir supplied; original APK capture comparison not performed")
        return 0

    module_path = android_root / "tools/oracle/compare_gait_oracle.py"
    spec = importlib.util.spec_from_file_location("chica_gait_oracle", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {module_path}")
    oracle = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = oracle
    spec.loader.exec_module(oracle)

    trace_names = (
        "api35_walk3_025_050_3_gaittrace.jsonl",
        "api35_walk2_025_050_2_gaittrace.jsonl",
        "api35_walk1_025_050_1_gaittrace.jsonl",
        "api35_walk15_025_050_4_gaittrace.jsonl",
        "api35_walk25_025_050_5_gaittrace.jsonl",
        "api35_walkwave_025_050_6_gaittrace.jsonl",
        "api35_crab_walk3_025_050_3_gaittrace.jsonl",
    )
    original_count = 0
    missing = []
    for trace_name in trace_names:
        trace_path = oracle_dir / trace_name
        if not trace_path.is_file():
            missing.append(trace_name)
            continue
        trace_frames, observed, _, quad_pair = oracle.parse_trace(trace_path)
        if not trace_frames or not observed:
            print(f"{trace_name}: no captured gait/pulse frames")
            return 1
        if quad_pair is not None:
            raise RuntimeError(f"unexpected quad trace in {trace_path}")
        trace_args: list[str] = []
        for frame in trace_frames:
            trace_args += ["--frame", ",".join(str(value) for value in frame)]
        trace_text = subprocess.run(
            [str(ios_probe), *trace_args], text=True, capture_output=True, check=True
        ).stdout
        rebuilt = [ast.literal_eval(line) for line in trace_text.splitlines() if line.startswith("[")]
        if any(len(frame) != 18 for frame in observed + rebuilt):
            print(f"{trace_name}: expected 18 channels per frame")
            return 1
        if len(observed) != len(rebuilt):
            print(
                f"{trace_name}: frame count mismatch: "
                f"original={len(observed)} rebuilt={len(rebuilt)}"
            )
            return 1
        if rebuilt != observed:
            for index, (expected_frame, actual_frame) in enumerate(zip(observed, rebuilt)):
                if expected_frame != actual_frame:
                    diffs = [abs(left - right) for left, right in zip(expected_frame, actual_frame)]
                    print(f"{trace_name} frame {index} differs: max={max(diffs)} sum={sum(diffs)}")
                    break
            return 1
        original_count += len(observed)
    print(f"iOS bridge matched {original_count} supplied APK gait frames")

    runtime_module_path = android_root / "tools/oracle/compare_walk_runtime_replay.py"
    runtime_spec = importlib.util.spec_from_file_location("chica_walk_runtime", runtime_module_path)
    if runtime_spec is None or runtime_spec.loader is None:
        raise RuntimeError(f"unable to load {runtime_module_path}")
    runtime_oracle = importlib.util.module_from_spec(runtime_spec)
    sys.modules[runtime_spec.name] = runtime_oracle
    runtime_spec.loader.exec_module(runtime_oracle)
    runtime_count = 0
    for trace_name in (
        "controltrace_walk_runtime_virtualtouch_original.jsonl",
        "controltrace_walkclear_dense_virtualtouch_original.jsonl",
    ):
        trace_path = oracle_dir / trace_name
        if not trace_path.is_file():
            missing.append(trace_name)
            continue
        trace_frames, observed = runtime_oracle.parse_trace(trace_path)
        if not trace_frames or not observed:
            print(f"{trace_name}: no captured runtime frames")
            return 1
        trace_args = []
        for frame in trace_frames:
            trace_args += ["--frame", ",".join(str(value) for value in frame)]
        trace_text = subprocess.run(
            [str(ios_probe), *trace_args], text=True, capture_output=True, check=True
        ).stdout
        rebuilt = [ast.literal_eval(line) for line in trace_text.splitlines() if line.startswith("[")]
        if any(len(frame) != 18 for frame in observed + rebuilt):
            print(f"{trace_name}: expected 18 channels per frame")
            return 1
        if rebuilt != observed:
            print(f"{trace_name}: runtime pulse mismatch")
            return 1
        runtime_count += len(observed)
    print(f"iOS bridge matched {runtime_count} supplied APK runtime frames")
    if missing:
        print("incomplete capture coverage; missing files:")
        for name in missing:
            print(f"  {name}")
        return 2
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-root", type=pathlib.Path,
                        default=pathlib.Path(os.environ.get("CHICA_ANDROID_ROOT", ROOT.parent / "android-server")),
                        help="Android reconstruction checkout (default: neighboring android-server directory)")
    parser.add_argument("--oracle-dir", type=pathlib.Path,
                        default=os.environ.get("CHICA_ORACLE_DIR"),
                        help="optional original APK captures; also accepts CHICA_ORACLE_DIR")
    args = parser.parse_args()
    android = args.android_root.expanduser().resolve()
    required = ("tools/oracle/gait_probe.cpp", "app/src/main/cpp/apk_model.cpp",
                "app/src/main/cpp/pulse_conversion.cpp")
    for name in required:
        if not (android / name).is_file():
            parser.error(f"Android checkout is missing {name}; set --android-root to your chica-server clone")
    oracle_dir = args.oracle_dir.expanduser().resolve() if args.oracle_dir else None
    if oracle_dir is not None and not oracle_dir.is_dir():
        parser.error(f"oracle directory not found: {oracle_dir}")
    with tempfile.TemporaryDirectory(prefix="chica-gait-") as temp:
        ios_probe, android_probe = build(android, pathlib.Path(temp))
        return compare(android, oracle_dir, ios_probe, android_probe)


if __name__ == "__main__":
    raise SystemExit(main())
