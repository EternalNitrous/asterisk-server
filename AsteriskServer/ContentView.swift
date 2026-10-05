import Foundation
import Network
import SwiftUI
import UIKit
#if canImport(CoreMotion)
import CoreMotion
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

private func monotonicMilliseconds() -> UInt64 {
  DispatchTime.now().uptimeNanoseconds / 1_000_000
}

/// Fullscreen server screen: a top button bar (Debug / Restart / Config), the
/// live hexapod visualizer with a bottom-left telemetry stack, and a bottom
/// button bar (Block / Torque / Sit).
struct ContentView: View {
  @State private var model = AsteriskServerModel()

  var body: some View {
    ServerScreen(model: model)
      .task { await model.startBridgeIfNeeded() }
  }
}

struct ServerScreen: View {
  @Bindable var model: AsteriskServerModel
  @State private var showSettings = false
  @State private var showConfig = false
  @State private var showDebug = false

  var body: some View {
    ZStack {
      ControllerBackdrop()

      VStack(spacing: 10) {
        HStack(spacing: 8) {
          barButton("Debug") {
            withAnimation(.easeInOut(duration: 0.28)) { showDebug.toggle() }
          }
          barButton("Restart") { Task { await model.restartService() } }
          barButton("Config") { showConfig = true }
        }

        ZStack {
          // Visualizer stays mounted (hidden under debug) so toggling never
          // reloads the CAD / replays the boot ramp.
          HexapodSceneView(joints: model.visualizerJoints, touches: model.legTouches)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(showDebug ? 0 : 1)
            .allowsHitTesting(!showDebug)
          TelemetryStack(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 6)
            .padding(.bottom, 4)
            .allowsHitTesting(false)
            .opacity(showDebug ? 0 : 1)
          if showDebug {
            DebugPanel(model: model) {
              withAnimation(.easeInOut(duration: 0.28)) { showDebug = false }
            }
            .transition(.opacity)
          }
        }

        HStack(spacing: 8) {
          barButton("Block", active: model.block) {
            Task { await model.handleLocalCommand("block") }
          }
          barButton("Torque", active: model.relayEnabled) {
            Task { await model.handleLocalCommand("torque") }
          }
          barButton("Sit", active: !model.standing) {
            Task { await model.handleLocalCommand("sit") }
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.top, 6)
      .padding(.bottom, 10)
    }
    .preferredColorScheme(.dark)
    .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
    .sheet(isPresented: $showConfig) { ConfigEditorView(model: model) }
  }

  private func barButton(_ title: String,
                         enabled: Bool = true,
                         active: Bool = false,
                         action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.protonMono(size: 15, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(enabled
                         ? (active ? Color(hex: "#eef2ff", opacity: 0.98) : Color(hex: "#f2f2f2", opacity: 0.9))
                         : Color(hex: "#f2f2f2", opacity: 0.32))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        // Proton's "on" cue: a glowing blue-white indicator dot on the leading edge.
        .overlay(alignment: .leading) {
          if active {
            Circle()
              .fill(Color(hex: "#dfe7ff", opacity: 0.95))
              .frame(width: 7, height: 7)
              .shadow(color: Color(hex: "#dfe7ff", opacity: 0.6), radius: 5)
              .padding(.leading, 14)
          }
        }
        .simulatedGlass(
          cornerRadius: 12,
          tint: active ? Color(hex: "#dfe7ff", opacity: 0.10) : Color(hex: "#ffffff", opacity: 0.03),
          highlightOpacity: active ? 0.30 : 0.14)
        // Blue outer glow when active (matches Proton's torque-on halo).
        .shadow(color: active ? Color(hex: "#8fa8ff", opacity: 0.32) : .clear, radius: 10, y: 2)
    }
    .buttonStyle(LiquidGlassButtonStyle())
    .disabled(!enabled)
  }
}

/// Compact telemetry readout (V / I / BPS / IP), left-aligned, JetBrains Mono,
/// pinned to the bottom-left above the control buttons.
struct TelemetryStack: View {
  @Bindable var model: AsteriskServerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      row("V", model.voltage.isFinite ? String(format: "%.2f", model.voltage) : "---",
          levelColor(model.voltageLevelState))
      row("I", model.current.isFinite ? String(format: "%.2f", model.current) : "---",
          levelColor(model.currentLevelState))
      row("BPS", "\(model.bps)", model.bpsHealthy ? okColor : Color(hex: "#ff6464"))
      row("IP", model.infoIPText, Color(hex: "#e5e5e5", opacity: 0.7))
      row("FLAGS", model.flagsString, Color(hex: "#8fa8ff", opacity: 0.85))
    }
    .font(.protonMono(size: 12.5, weight: .medium))
    .textCase(.uppercase)
    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
  }

  private let okColor = Color(hex: "#67e8a5")

  private func levelColor(_ state: Int) -> Color {
    state == 2 ? Color(hex: "#ff6464") : state == 1 ? Color(hex: "#f2c94c") : okColor
  }

  private func row(_ label: String, _ value: String, _ color: Color) -> some View {
    HStack(spacing: 6) {
      Text(label)
        .foregroundStyle(Color(hex: "#e5e5e5", opacity: 0.5))
        .frame(width: 48, alignment: .leading)
      Text(value)
        .foregroundStyle(color)
      Spacer(minLength: 0)
    }
  }
}

/// Debug overlay: joystick (client walk vector), the active command line, and
/// the exact per-leg PWM being sent — centered, with a header (connection type
/// + close).
struct DebugPanel: View {
  @Bindable var model: AsteriskServerModel
  var onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("CONN \(model.connectionType)")
          .font(.protonMono(size: 13, weight: .semibold))
          .textCase(.uppercase)
          .foregroundStyle(Color(hex: "#8fa8ff", opacity: 0.85))
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(hex: "#f2f2f2", opacity: 0.75))
            .frame(width: 36, height: 36)
            .simulatedGlass(cornerRadius: 11,
                            tint: Color(hex: "#ffffff", opacity: 0.03),
                            highlightOpacity: 0.14)
        }
        .buttonStyle(LiquidGlassButtonStyle())
      }
      .padding(.horizontal, 4)
      .padding(.top, 4)

      Spacer(minLength: 8)

      VStack(spacing: 20) {
        JoystickView(forward: model.poseCommandY, strafe: model.poseCommandX, turn: model.poseCommandTurn)
          .frame(width: 300, height: 250)

        Text(model.activeCommandText)
          .font(.protonMono(size: 16, weight: .semibold))
          .textCase(.uppercase)
          .foregroundStyle(Color(hex: "#dfe7ff", opacity: 0.95))
          .padding(.horizontal, 18)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(Color(hex: "#ffffff", opacity: 0.04)))

        PulseGrid(legs: model.legServoPulses)
      }

      Spacer(minLength: 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// 2-axis pad for the translation stick (strafe = x, forward = y) plus numeric
/// readouts of forward / strafe / turn.
struct JoystickView: View {
  let forward: Double, strafe: Double, turn: Double

  var body: some View {
    VStack(spacing: 8) {
      GeometryReader { geo in
        let s = min(geo.size.width, geo.size.height)
        let r = s / 2 - 12
        ZStack {
          Circle().stroke(Color(hex: "#ffffff", opacity: 0.14), lineWidth: 1)
          Rectangle().fill(Color(hex: "#ffffff", opacity: 0.07)).frame(height: 1)
          Rectangle().fill(Color(hex: "#ffffff", opacity: 0.07)).frame(width: 1)
          Circle()
            .fill(Color(hex: "#dfe7ff", opacity: 0.95))
            .frame(width: 18, height: 18)
            .shadow(color: Color(hex: "#8fa8ff", opacity: 0.6), radius: 6)
            .offset(x: clamp(strafe) * r, y: -clamp(forward) * r)
        }
        .frame(width: s, height: s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      HStack(spacing: 12) {
        readout("FWD", forward)
        readout("STR", strafe)
        readout("TURN", turn)
      }
      .font(.protonMono(size: 11, weight: .medium))
      .textCase(.uppercase)
      .lineLimit(1)
      .fixedSize()
    }
  }

  private func clamp(_ v: Double) -> Double { min(1, max(-1, v)) }

  private func readout(_ label: String, _ value: Double) -> some View {
    HStack(spacing: 4) {
      Text(label).foregroundStyle(Color(hex: "#e5e5e5", opacity: 0.4))
      Text(String(format: "%+.2f", value)).foregroundStyle(Color(hex: "#dfe7ff", opacity: 0.9))
    }
  }
}

/// Per-leg PWM: the three right legs on top, the three left legs below, so R1
/// sits directly above L1. Each leg is a column headed by its name, then its
/// three joint pulses ("1: 1723").
struct PulseGrid: View {
  let legs: [(name: String, pulses: [Int])]   // [L1,L2,L3,R1,R2,R3]

  var body: some View {
    VStack(spacing: 16) {
      legRow(Array(legs.count >= 6 ? Array(legs[3...5]) : legs))   // R1 R2 R3
      legRow(Array(legs.count >= 6 ? Array(legs[0...2]) : []))     // L1 L2 L3
    }
    .font(.protonMono(size: 12.5, weight: .medium))
    .textCase(.uppercase)
    .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
  }

  private func legRow(_ row: [(name: String, pulses: [Int])]) -> some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(Array(row.enumerated()), id: \.offset) { _, leg in
        VStack(alignment: .leading, spacing: 3) {
          Text(leg.name)
            .foregroundStyle(Color(hex: "#8fa8ff", opacity: 0.9))
          ForEach(Array(leg.pulses.enumerated()), id: \.offset) { joint, pulse in
            Text(verbatim: "\(joint + 1): \(pulse)")
              .foregroundStyle(Color(hex: "#e5e5e5", opacity: 0.85))
              .lineLimit(1)
              .minimumScaleFactor(0.6)
          }
        }
        .frame(width: 80, alignment: .leading)
      }
    }
  }
}

/// The former Form-based control panel, now reached from the Config button.
struct SettingsSheet: View {
  @Bindable var model: AsteriskServerModel
  @State private var manualCommand = "ack"
  @State private var showConfig = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Bridge") {
          LabeledContent("Hardware") {
            TextField("192.168.204.1", text: $model.hardwareHost)
              .keyboardType(.numbersAndPunctuation)
              .multilineTextAlignment(.trailing)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }

          LabeledContent("Port") {
            TextField("18712", text: $model.hardwarePort)
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
          }

          Button {
            Task { await model.toggleBridge() }
          } label: {
            Label(model.bridgeRunning ? "Stop AsteriskServer" : "Start AsteriskServer",
                  systemImage: model.bridgeRunning ? "stop.circle" : "play.circle")
          }
        }

        Section("Status") {
          statusRow("WebSocket", model.webSocketState, model.webSocketState == "listening" ? .green : .secondary)
          statusRow("TCP", model.serverState, model.serverState == "listening" ? .green : .secondary)
          statusRow("Hardware", model.hardwareState, model.hardwareConnected ? .green : .orange)
          LabeledContent("Client", value: model.clientEndpoint)
            .textSelection(.enabled)
          Text(model.originalStatusLine)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
        }

        Section("Robot") {
          HStack {
            Button {
              Task { await model.handleLocalCommand("torque") }
            } label: {
              Label(model.relayEnabled ? "Torque Off" : "Torque On", systemImage: "power")
            }

            Button {
              Task { await model.handleLocalCommand("home") }
            } label: {
              Label("Home", systemImage: "house")
            }

            Button {
              Task { await model.handleLocalCommand("sit") }
            } label: {
              Label("Sit", systemImage: "arrow.down.to.line")
            }
          }

          HStack {
            TextField("Command", text: $manualCommand)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Button {
              Task { await model.handleLocalCommand(manualCommand) }
            } label: {
              Label("Send", systemImage: "paperplane")
            }
          }
        }

        Section("Debug") {
          Text(model.debugInfo)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
        }

        Section("Telemetry") {
          LabeledContent("Voltage", value: model.voltageText)
          LabeledContent("Current", value: model.currentText)
          LabeledContent("Touches", value: model.legsText)
          LabeledContent("BPS", value: "\(model.bps)")
        }

        Section("Configuration") {
          Button {
            showConfig = true
          } label: {
            Label("Edit Config", systemImage: "slider.horizontal.3")
          }
          Text(model.configSummary)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Section("Log") {
          if model.log.isEmpty {
            Text("No messages yet")
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.log) { entry in
              VStack(alignment: .leading, spacing: 4) {
                Text(entry.timestamp, style: .time)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(entry.message)
                  .font(.system(.footnote, design: .monospaced))
                  .textSelection(.enabled)
              }
              .padding(.vertical, 2)
            }
          }
        }
      }
      .navigationTitle("AsteriskServer")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            model.clearLog()
          } label: {
            Label("Clear", systemImage: "trash")
          }
          .disabled(model.log.isEmpty)
        }
      }
      .sheet(isPresented: $showConfig) {
        ConfigEditorView(model: model)
      }
    }
  }

  private func statusRow(_ title: String, _ value: String, _ color: Color) -> some View {
    HStack {
      Image(systemName: "circle.fill")
        .foregroundStyle(color)
      LabeledContent(title, value: value)
    }
  }
}

struct ConfigEditorView: View {
  @Bindable var model: AsteriskServerModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var message: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if let message {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)
        }
        TextEditor(text: $draft)
          .font(.system(.footnote, design: .monospaced))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .padding(.horizontal, 4)
      }
      .navigationTitle("Config")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Reset") {
            draft = ChicaConfigStore.defaultConfigText
            message = "Loaded stock config-2040 (not yet saved)."
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") {
            Task {
              message = await model.saveConfig(draft)
            }
          }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
      .onAppear { draft = model.configText }
    }
  }
}

@MainActor
@Observable
final class AsteriskServerModel {
  struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
  }

  struct WalkCommandState {
    var forward = 0.0
    var strafe = 0.0
    var turn = 0.0

    var active: Bool {
      forward != 0 || strafe != 0 || turn != 0
    }
  }

  var hardwareHost = "192.168.204.1"
  var hardwarePort = "18712"

  private(set) var bridgeRunning = false
  private(set) var serverState = "stopped"
  private(set) var webSocketState = "stopped"
  private(set) var hardwareState = "disconnected"
  private(set) var hardwareConnected = false
  private(set) var connectionType = "-"   // active client transport: ws / tcp / -
  private(set) var relayEnabled = false
  private(set) var standing = false
  private(set) var keep = false
  private(set) var crab = false
  private(set) var mode = 0
  private(set) var level = false
  private(set) var autoSit = true
  private(set) var block = false
  private(set) var calibPosition = false
  private(set) var bps = 0
  private(set) var voltage = Double.nan
  private(set) var current = Double.nan
  private(set) var legTouches = Array(repeating: Double.nan, count: 6)
  private(set) var log: [LogEntry] = []
  private(set) var configText = ChicaConfigStore.defaultConfigText
  private(set) var configSummary = ""
  // Live walk/motion-worker state, for diagnosing stop/resume snaps on-device.
  private(set) var debugInfo = "—"
  private var debugTick = 0

  private var config = ChicaConfig.parse(ChicaConfigStore.defaultConfigText)
  private var server: ChicaControlServer?
  private var wsServer: ChicaWebSocketServer?
  private var hardware = Servo2040TCPHardware()
  private let beeper = ChicaBeeper()
  // Original z0.f.f7069e: pending beep count consumed by the beeper worker
  // (z0/c TimerTask: N tones at 200 ms spacing, then a 1 s hold).
  private var beepCount = 0
  private var beeperTask: Task<Void, Never>?
  // Latch so the warning-cutoff "torque" command is submitted once per
  // over-limit episode (original gates via the f7078o command-in-flight flag).
  private var cutoffTorquePending = false
  private let gaitEngine = ChicaGaitEngineBridge()
  private var pollTask: Task<Void, Never>?
  private var lastClientLineAt = Date.distantPast
  private var autoRestartOnConnect = false   // armed when the bridge boots with no board
  private var walkTask: Task<Void, Never>?
  // setclear clears the logical motion flag while its task finishes releasing.
  // Track every task so overlapping releases can still be cancelled on stop.
  private var setWorkerRunning = false
  private var setTasks: [UUID: Task<Void, Never>] = [:]
  private var levelTask: Task<Void, Never>?
  private var startedOnce = false
  private var lastPulses = Array(repeating: 1500, count: 18) {
    didSet { refreshVisualizerJoints() }
  }
  /// Live per-leg joint chain for the visualizer, pushed whenever the pose
  /// changes (any lastPulses assignment). Push-based so the visualizer never
  /// polls the engine on a render timer — which would starve the async pose
  /// ramps sharing the main actor.
  private(set) var visualizerJoints: [[SIMD3<Double>]] = []
  private var commandTask: Task<Void, Never>?
  private var busy = false

  // walk state
  private var activeWalk = false
  private var pendingStopStep = false
  private var pendingWalkClear = false
  private var walkStepCount = 0
  private var lastStepMillis = monotonicMilliseconds()
  private var walkModeIndex = -1
  private var gait = 1
  private var animation = 0
  private var lastWalk = WalkCommandState()
  private var filteredWalk = WalkCommandState()

  // set-pose state. primary = (x,y) translation, secondary = (v,w) pitch/yaw,
  // tertiary = (z,u) height/roll. The original rebuilds the full 6-DOF target
  // from each set command, so a command zeroes the axes it doesn't drive.
  private var lastPrimaryX = 0.0
  private var lastPrimaryY = 0.0
  private var lastSecondaryX = 0.0
  private var lastSecondaryY = 0.0
  private var lastTertiaryX = 0.0
  private var lastTertiaryY = 0.0
  // Continuous angular-sweep set-poses (the original's worker case 2, p3.a.G):
  // 0 = static set-pose integrator, 1 = dive (z5=true), 2 = setrotate/flex (z5=false).
  private var setSweepMode = 0
  private var setPoseTargetActive = false

  // mode / output
  private var activeOutputLegs: [Int] = ChicaConst.allLegs
  private var quadrupedActiveLegs: [Int] = [0, 3, 2, 5]

  // level / orientation
  private(set) var orientationX = 0.0
  private(set) var orientationY = 0.0
  #if canImport(CoreMotion)
  private let motionManager = CMMotionManager()
  #endif

  // warning/cutoff timers
  private var voltageWarnSince = Date()
  private var voltageCutSince = Date()
  private var currentWarnSince = Date()
  private var currentCutSince = Date()
  private(set) var voltageWarning = false
  private(set) var currentWarning = false

  private let originalPoseStepMs = 10.0
  private let originalStopVectorThreshold = 0.2

  var originalStatusLine: String { "ready:" + originalStatusString() }
  var clientEndpoint: String { "\(localIPAddress() ?? "Wi-Fi unavailable"):18711" }

  var voltageText: String { voltage.isFinite ? String(format: "%.2f V", voltage) : "---" }
  var currentText: String { current.isFinite ? String(format: "%.2f A", current) : "---" }
  var legsText: String {
    String(legTouches.map { $0.isFinite && $0 > 0.5 ? "x" : "-" })
  }

  // MARK: - Telemetry feed (voltage/current colour thresholds mirror z0.d)

  /// 0 = ok/green, 1 = warning/yellow, 2 = critical/red. Voltage falls, so
  /// below cutoff = red, below warning = yellow (original d.java: d2<h.C?red:d2<h.B?yellow:green).
  var voltageLevelState: Int {
    guard voltage.isFinite else { return 0 }
    if voltage < config.voltageCutoffLevel { return 2 }
    if voltage < config.voltageWarningLevel { return 1 }
    return 0
  }

  /// Current rises, so above cutoff = red, above warning = yellow.
  var currentLevelState: Int {
    guard current.isFinite else { return 0 }
    if current > config.currentCutoffLevel { return 2 }
    if current > config.currentWarningLevel { return 1 }
    return 0
  }

  /// Original: bps > 100 → cyan (healthy), else red.
  var bpsHealthy: Bool { Double(bps) > 100.0 }

  var infoIPText: String { localIPAddress() ?? "0.0.0.0" }

  /// Status flag bits for the telemetry stack: relay, standing, keep, crab,
  /// mode digit, level, autoSit, block, calibPosition (same order the protocol
  /// FLAGS field uses).
  var flagsString: String {
    [relayEnabled, standing, keep, crab].map { $0 ? "1" : "0" }.joined()
      + String(min(max(mode, 0), 9))
      + [level, autoSit, block, calibPosition].map { $0 ? "1" : "0" }.joined()
  }

  /// Pose gauge feed: the filtered walk command (strafe = x, forward = y, turn).
  var poseCommandX: Double { filteredWalk.strafe }
  var poseCommandY: Double { filteredWalk.forward }
  var poseCommandTurn: Double { filteredWalk.turn }

  // MARK: - Debug panel feed

  var isWalking: Bool { activeWalk }
  var crabMode: Bool { crab }

  /// One-line active-command summary, e.g. "walk, tripod".
  var activeCommandText: String {
    if activeWalk { return "walk, \(gaitStyleName)" }
    if block { return "block" }
    return standing ? "stand" : "sit"
  }

  private var gaitStyleName: String {
    switch gaitForMode() {
    case 20: return "quad"
    case 10: return "wave"
    case 9:  return "walk25"
    case 8:  return "walk15"
    case 7:  return "walk1"
    case 6:  return "walk2"
    default: return "tripod"   // apk 5 (walk3) — the standard fast gait
    }
  }

  /// Exact per-leg servo pulses being sent: leg name + its 3 joint PWMs, using
  /// the config's leg/joint→pin map to index the flat pulse array.
  var legServoPulses: [(name: String, pulses: [Int])] {
    let names = ["L1", "L2", "L3", "R1", "R2", "R3"]
    return (0..<6).map { leg in
      (names[leg], (0..<3).map { joint in
        let pin = config.servoPins[leg][joint].number
        return lastPulses.indices.contains(pin) ? lastPulses[pin] : 0
      })
    }
  }

  /// Restart the whole service (stop then start the bridge).
  func restartService() async {
    if bridgeRunning { await stopBridge() }
    await startBridge()
  }

  /// Recompute the visualizer's per-leg joint chain from the live engine pose
  /// (forward kinematics). Shape [6][4] (leg → mount, hip, knee, foot). Called
  /// from lastPulses.didSet and the startup seed; runs on the main actor, the
  /// same isolation the gait steps use, so it never races the engine state.
  func refreshVisualizerJoints() {
    let flat = gaitEngine.legJointPositions()
    guard flat.count == 72 else { return }
    var legs: [[SIMD3<Double>]] = []
    legs.reserveCapacity(6)
    for leg in 0..<6 {
      var joints: [SIMD3<Double>] = []
      joints.reserveCapacity(4)
      for j in 0..<4 {
        let base = (leg * 4 + j) * 3
        joints.append(SIMD3(flat[base].doubleValue, flat[base + 1].doubleValue, flat[base + 2].doubleValue))
      }
      legs.append(joints)
    }
    visualizerJoints = legs
  }

  init() {
    configText = ChicaConfigStore.load()
    applyConfig(configText)
    // Seed the engine with the neutral standing pose so the visualizer shows a
    // proper hexapod at rest before any command drives it (the startup ramp then
    // takes over once the bridge starts).
    _ = gaitEngine.enterNeutralPose(bodyZ: currentMode().bodyLift)
    refreshVisualizerJoints()
    // Optional override for bench testing against a host-side fake board.
    if let host = ProcessInfo.processInfo.environment["CHICA_HW_HOST"], !host.isEmpty {
      hardwareHost = host
    }
  }

  // MARK: - Config

  private func applyConfig(_ text: String) {
    config = ChicaConfig.parse(text)
    configText = text
    configSummary = config.summary
    gaitEngine.configureGeometry(
      coxa: config.coxaLen, femur: config.femurLen, tibia: config.tibiaLen,
      l1ToR1: config.l1ToR1, l1ToL3: config.l1ToL3, l2ToR2: config.l2ToR2,
      legConnectionZ: config.legConnectionZ, legSittingZ: config.legSittingZ)
    gaitEngine.setServoConfig(
      calibration: config.flatCalibration.map { NSNumber(value: $0) },
      coxaAttach: config.coxaAttach.map { NSNumber(value: $0) },
      femurAttach: config.femurAttach, tibiaAttach: config.tibiaAttach,
      pins: config.flatPins.map { NSNumber(value: $0) })
    applyModeConfig()
  }

  func saveConfig(_ text: String) async -> String {
    guard ChicaConfig.isValid(text) else {
      return "Invalid config (need >=18 servo/touch device lines); not saved."
    }
    let restartService = bridgeRunning
    if restartService {
      record("config valid; restarting service")
      await stopBridge()
    }
    ChicaConfigStore.save(text)
    applyConfig(text)
    if restartService {
      await sleepPoseStep(100)
      await startBridge()
    }
    record("config saved and applied (\(config.summary))")
    return restartService ? "Saved and restarted. \(config.summary)" : "Saved. \(config.summary)"
  }

  // MARK: - Lifecycle

  func startBridgeIfNeeded() async {
    guard !startedOnce else { return }
    startedOnce = true
    startBeeperWorker()
    await startBridge()
  }

  func toggleBridge() async {
    if bridgeRunning { await stopBridge() } else { await startBridge() }
  }

  func startBridge() async {
    guard let portValue = UInt16(hardwarePort) else {
      record("ERR invalid hardware port \(hardwarePort)")
      return
    }

    // Start the control server FIRST and independently of the hardware link, so
    // a missing/unreachable Servo2040 never blocks the LAN listener (the original
    // serves clients regardless of board state). Hardware connects lazily.
    do {
      let controlServer = ChicaControlServer(port: ChicaPorts.tcp)
      controlServer.onLog = { [weak self] message in
        Task { @MainActor in self?.record(message) }
      }
      controlServer.onState = { [weak self, weak controlServer] state in
        Task { @MainActor in
          guard let self, let controlServer, self.server === controlServer else { return }
          self.serverState = state
        }
      }
      controlServer.initialLine = { [weak self] in
        await MainActor.run { "ready:" + (self?.originalStatusString() ?? ChicaConst.idleStatus) }
      }
      controlServer.process = { [weak self] line, session in
        await MainActor.run {
          self?.noteClient("tcp")
          return self?.processProtocolLine(line, session: session)
        }
      }
      server = controlServer
      try controlServer.start()
      serverState = "starting"
      bridgeRunning = true
      UIApplication.shared.isIdleTimerDisabled = true
      record("control server listening on tcp/\(ChicaPorts.tcp)")
      record("configure Chica Client server IP as \(localIPAddress() ?? "the iPhone Wi-Fi address")")
    } catch {
      server = nil
      serverState = "failed"
      record("control server failed: \(error.localizedDescription)")
    }

    // Primary transport: a WebSocket server speaking the identical line protocol.
    // Clients that support it should prefer WebSocket; the raw-TCP server above
    // stays up for legacy clients. Both share the same command handlers/state.
    do {
      let socketServer = ChicaWebSocketServer(port: ChicaPorts.webSocket)
      socketServer.onLog = { [weak self] message in
        Task { @MainActor in self?.record(message) }
      }
      socketServer.onState = { [weak self, weak socketServer] state in
        Task { @MainActor in
          guard let self, let socketServer, self.wsServer === socketServer else { return }
          self.webSocketState = state
        }
      }
      socketServer.initialLine = { [weak self] in
        await MainActor.run { "ready:" + (self?.originalStatusString() ?? ChicaConst.idleStatus) }
      }
      socketServer.process = { [weak self] line, session in
        await MainActor.run {
          self?.noteClient("ws")
          return self?.processProtocolLine(line, session: session)
        }
      }
      wsServer = socketServer
      try socketServer.start()
      webSocketState = "starting"
      record("websocket server listening on ws/\(ChicaPorts.webSocket)")
    } catch {
      wsServer = nil
      webSocketState = "failed"
      record("websocket server failed: \(error.localizedDescription)")
    }

    hardware = Servo2040TCPHardware(host: hardwareHost, port: NWEndpoint.Port(rawValue: portValue)!)
    Task { @MainActor in
      do {
        try await hardware.connect()
        hardwareConnected = true
        hardwareState = "connected"
        record("hardware connected \(hardwareHost):\(portValue)")
        beepCount = 1   // z0.f.b(): one beep on a successful board open
        autoRestartOnConnect = false   // booted with the board present
      } catch {
        hardwareConnected = false
        hardwareState = "connect failed"
        record("hardware connect failed: \(error.localizedDescription)")
        beepCount = 6   // z0.f.b(): six beeps on a failed board open
        autoRestartOnConnect = true    // arm: restart when the board later connects
      }
    }

    startPolling()
    startOrientationUpdates()
    await enterStartupPose()
    // Mirror the original: after the startup shape ramp, boot into a standing
    // pose with torque on (fresh-launch status FLAGS=110000100).
    _ = await setOriginalStanding(true, powerOffAfterSit: false)
  }

  func stopBridge() async {
    server?.stop()
    server = nil
    wsServer?.stop()
    wsServer = nil
    pollTask?.cancel(); pollTask = nil
    commandTask?.cancel(); commandTask = nil
    stopWalking(cancelTask: true)
    for task in setTasks.values { task.cancel() }
    setTasks.removeAll()
    resetSetControls()
    levelTask?.cancel(); levelTask = nil
    stopOrientationUpdates()
    if relayEnabled && hardwareConnected {
      try? await hardware.setRelay(false, configuredAs: config.hardwareIO.relay)
    }
    await hardware.cancel()
    busy = false
    relayEnabled = false
    standing = false
    bridgeRunning = false
    serverState = "stopped"
    webSocketState = "stopped"
    hardwareState = "disconnected"
    hardwareConnected = false
    UIApplication.shared.isIdleTimerDisabled = false
    record("bridge stopped")
  }

  func handleLocalCommand(_ command: String) async {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "ack", trimmed != "bye" else { return }
    if busy { record("busy, ignoring \(trimmed)"); return }
    busy = true
    record("cmd \(trimmed)")
    await applyCommand(trimmed)
    busy = false
  }

  func clearLog() { log.removeAll() }

  // MARK: - Protocol (mirrors OriginalTcpControlServer.handleClient)

  func isBusy() -> Bool { busy }

  func shouldHandleOriginalAck() -> Bool {
    relayEnabled && !block && !calibPosition && !busy
  }

  func originalStatusString() -> String {
    // The mode position (index 4) carries the mode INDEX as a digit (the
    // original's o.n, appended as an int), not a boolean — otherwise every
    // non-standard mode collapses to "1" and the client labels them all "race".
    let flags = [relayEnabled, standing, keep, crab].map { $0 ? "1" : "0" }.joined()
      + String(min(max(mode, 0), 9))
      + [level, autoSit, block, calibPosition].map { $0 ? "1" : "0" }.joined()
    return String(
      format: "BPS=% 3d|V=%@|I=%@|IP=%@|LEGS=%@|FLAGS=%@",
      bps,
      voltage.isFinite ? String(format: "% 3.3f", voltage) : "---",
      current.isFinite ? String(format: "% 3.3f", current) : "---",
      localIPAddress() ?? "0.0.0.0",
      legsText,
      flags)
  }

  /// Record the transport of the client that just sent a line (for the debug
  /// readout); the poll clears it after a few seconds of silence.
  func noteClient(_ kind: String) {
    connectionType = kind
    lastClientLineAt = Date()
  }

  // Returns the reply line (without trailing newline), or nil to close the
  // connection (client sent bye / disconnected).
  func processProtocolLine(_ line: String, session: ChicaClientSession) -> String? {
    let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if command == "bye" {
      requestOriginalWalkStop(logTargetNull: false)
      return nil
    }
    if command.isEmpty {
      return "ready:" + originalStatusString()
    }
    record("tcp_recv \(command)")
    if command != "ack" { session.ackCount = 0 }
    if isBusy() {
      return "busy:" + originalStatusString()
    }
    if command == "ack" && shouldHandleOriginalAck() {
      session.ackCount += 1
      handleOriginalAck(session.ackCount)
      return "ready:" + originalStatusString()
    }
    submitOriginalCommand(command)
    return "ready:" + originalStatusString()
  }

  private func submitOriginalCommand(_ command: String) {
    if command.isEmpty || command == "ack" || command == "bye" { return }
    busy = true
    commandTask = Task { @MainActor in
      await applyCommand(command)
      busy = false
    }
  }

  private func handleOriginalAck(_ ackCount: Int) {
    busy = true
    commandTask = Task { @MainActor in
      if ackCount <= 30 {
        await publishHomePose(threshold: 50.0 - Double(ackCount))
      } else if ackCount == 60 && autoSit {
        if standing && !activeWalk {
          record("ack_autosit")
          await enterSitPose()
          standing = false
          setRelayState(false)
          await publishRelay(false)
        }
      }
      busy = false
    }
  }

  // MARK: - Command dispatch (mirrors ChicaController.applyCommand)

  private func applyCommand(_ command: String) async {
    if command.hasPrefix("torque") {
      await setOriginalRelay(!relayEnabled)
    } else if command.hasPrefix("sit") {
      _ = await setOriginalStanding(!standing, powerOffAfterSit: false)
      activeWalk = standing && lastWalk.active
    } else if command.hasPrefix("calibpos") {
      await setOriginalCalibPosition(!calibPosition)
    } else if command.hasPrefix("block") {
      await setOriginalBlockMode(!block, force: false)
    } else if command.hasPrefix("autosit") {
      autoSit.toggle()
    } else if command.hasPrefix("level") {
      level.toggle()
      if level { startLevelWorker() }
    } else if command.hasPrefix("crab") {
      crab.toggle()
    } else if command.hasPrefix("keep") {
      keep.toggle()
      if !keep { await publishOriginalLayerFade() }
    } else if command.hasPrefix("home") {
      await enterOriginalHomePose()
    } else if command.hasPrefix("bounce") {
      await runOriginalBounce()
    } else if command.hasPrefix("jump") {
      await runOriginalJump()
    } else if command.hasPrefix("calibrate") {
      await runOriginalCalibrate()
    } else if command.hasPrefix("reboot") {
      await setOriginalRelay(false)
      record("reboot requested (no-op on iOS bridge)")
    } else if command.hasPrefix("restart") {
      await setOriginalRelay(false)
      await stopBridge()
      await startBridge()
    } else if command.hasPrefix("standard") {
      await applyOriginalMode(0)
    } else if command.hasPrefix("race") {
      await applyOriginalMode(1)
    } else if command.hasPrefix("offroad") {
      await applyOriginalMode(2)
    } else if command.hasPrefix("custom") {
      await applyOriginalMode(3)
    } else if command.hasPrefix("quad") {
      if let disabledLegs = parseQuadDisabledLegs(command) {
        await applyOriginalQuadMode(disabledLegs)
      }
    } else if command.hasPrefix("walkclear") {
      requestOriginalWalkStop(logTargetNull: true)
    } else if command.hasPrefix("walk") {
      await applyWalkCommand(command)
    } else if command.hasPrefix("clear") {
      activeWalk = false
      pendingWalkClear = false
      pendingStopStep = false
      lastWalk = WalkCommandState()
      filteredWalk = WalkCommandState()
      walkStepCount = 0
      walkModeIndex = -1
      resetSetControls()
      if relayEnabled && !originalMotionBusy() {
        _ = await setOriginalStanding(false, powerOffAfterSit: true)
      }
    } else if command.hasPrefix("setclear") {
      resetSetControls()
    } else if command.hasPrefix("set") {
      applySetCommand(command)
    } else if command.hasPrefix("beep") {
      beeper.beep()
    } else {
      record("unknown command \(command)")
    }
  }

  // MARK: - Relay / posture

  private func setRelayState(_ enabled: Bool) {
    relayEnabled = enabled
  }

  private func setOriginalRelay(_ enabled: Bool) async {
    if enabled == relayEnabled { return }
    if enabled {
      relayEnabled = true
      await publishRelay(true)
      return
    }
    if originalMotionBusy() { return }
    if standing {
      _ = await setOriginalStanding(false, powerOffAfterSit: false)
    }
    relayEnabled = false
    await publishRelay(false)
  }

  @discardableResult
  private func setOriginalStanding(_ enabled: Bool, powerOffAfterSit: Bool) async -> Bool {
    if block { await setOriginalBlockMode(false, force: false) }
    if calibPosition { await setOriginalCalibPosition(false) }
    if enabled == standing { return true }
    if enabled {
      await setOriginalRelay(true)
      await enterStandPose()
      standing = true
    } else {
      if originalMotionBusy() { return false }
      await enterSitPose()
      standing = false
      if powerOffAfterSit {
        relayEnabled = false
        await publishRelay(false)
      }
    }
    return true
  }

  private func setOriginalBlockMode(_ enabled: Bool, force: Bool) async {
    if enabled == block && !force { return }
    let wasRelayOn = relayEnabled
    if enabled {
      if originalMotionBusy() { return }
      if !(await setOriginalStanding(false, powerOffAfterSit: false)) { return }
      await setOriginalRelay(true)
      await publishBlockShapeRamp()
      block = true
      return
    }
    await setOriginalRelay(true)
    await publishBlockRaisedRamp()
    await publishSittingShapeRamp(currentMode())
    if !wasRelayOn { await setOriginalRelay(false) }
    block = false
  }

  private func setOriginalCalibPosition(_ enabled: Bool) async {
    if enabled == calibPosition { return }
    let wasRelayOn = relayEnabled
    if enabled {
      if originalMotionBusy() { return }
      if !(await setOriginalStanding(false, powerOffAfterSit: false)) { return }
      await setOriginalRelay(true)
      await publishBlockRaisedRamp()
      await publishCalibPoseRamp()
      calibPosition = true
      return
    }
    await setOriginalRelay(true)
    await publishBlockRaisedRamp()
    await publishSittingShapeRamp(currentMode())
    if !wasRelayOn { await setOriginalRelay(false) }
    calibPosition = false
  }

  private func originalMotionBusy() -> Bool {
    // The APK reads motion flags, not whether a draining task is still alive.
    activeWalk || setWorkerRunning
  }

  // MARK: - Pose animations (timed)

  private func enterStartupPose() async {
    // Original boot = o() ctor -> i([], 0): old mode is the sentinel 9, so it
    // runs the block-mode EXIT with force (a(false, true)) — raise to the block
    // row + (80, 100) then settle to MODE_STANDARD at sitting z. Derive from the
    // parsed mode table so custom configs boot exactly.
    lastPulses = pulses(from: gaitEngine.enterConstructorPose())
    await publishPulses(lastPulses)
    let b = config.modes[5]
    let std = config.modes[0]
    await runShapeRamp(radius: b.radius + 80, z: b.bodyLift + 100, corner: b.cornerAngle, elongation: b.elongation, durationMs: 800.0 / std.speed)
    await runShapeRamp(radius: std.radius, z: config.legSittingZ, corner: std.cornerAngle, elongation: std.elongation, durationMs: 1200.0 / std.speed)
  }

  private func enterStandPose() async {
    let mode = currentMode()
    await publishHomePose(threshold: 10)
    await runBodyZRamp(bodyZ: mode.bodyLift, durationMs: 400.0 / mode.speed)
  }

  private func enterSitPose() async {
    let mode = currentMode()
    await publishHomePose(threshold: 20)
    await runBodyZRamp(bodyZ: 0, durationMs: 550.0 / mode.speed)
  }

  private func enterOriginalHomePose() async {
    await publishHomePose(threshold: -1)
  }

  private func publishHomePose(threshold: Double) async {
    if originalMotionBusy() { return }
    // g() powers torque before M(), even if no feet need to move.
    await setOriginalRelay(true)
    let mode = currentMode()
    let lift = standing ? mode.stepLift : 15.0
    let layerBlend = standing ? mode.animationFactor : 0.0
    let duration = 650.0 / mode.speed
    if self.mode == 4 {
      if standing {
        for leg in quadrupedActiveLegs {
          await runPoseRamp(legs: [leg], threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: duration)
        }
      } else {
        await runPoseRamp(legs: quadrupedActiveLegs, threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: duration)
      }
      return
    }
    if standing {
      await runPoseRamp(legs: ChicaConst.standLeftTripod, threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: duration)
      await runPoseRamp(legs: ChicaConst.standRightTripod, threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: duration)
    } else {
      await runPoseRamp(legs: ChicaConst.allLegs, threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: duration)
    }
  }

  private func runPoseRamp(legs: [Int], threshold: Double, lift: Double, layerBlend: Double, durationMs: Double) async {
    let legNums = legs.map { NSNumber(value: $0) }
    if !gaitEngine.beginPoseRampToNeutral(legs: legNums, threshold: threshold, lift: lift, layerBlend: layerBlend, durationMs: durationMs) { return }
    await runTimedAnimation(durationMs: durationMs)
  }

  private func runBodyZRamp(bodyZ: Double, durationMs: Double) async {
    if !gaitEngine.beginBodyZRamp(bodyZ: bodyZ, durationMs: durationMs) { return }
    await runTimedAnimation(durationMs: durationMs)
  }

  private func runBodyZDeltaRamp(bodyZDelta: Double, durationMs: Double) async {
    if !gaitEngine.beginBodyZDeltaRamp(bodyZDelta: bodyZDelta, durationMs: durationMs) { return }
    await runTimedAnimation(durationMs: durationMs)
  }

  private func runShapeRamp(radius: Double, z: Double, corner: Double, elongation: Double, durationMs: Double) async {
    if !gaitEngine.beginShapeRamp(radius: radius, z: z, cornerAngleDeg: corner, elongation: elongation, durationMs: durationMs) { return }
    await runTimedAnimation(durationMs: durationMs)
  }

  private func runShapeRampForLegs(legs: [Int], radius: Double, z: Double, corner: Double, elongation: Double, durationMs: Double) async {
    let legNums = legs.map { NSNumber(value: $0) }
    if !gaitEngine.beginShapeRampForLegs(legs: legNums, radius: radius, z: z, cornerAngleDeg: corner, elongation: elongation, durationMs: durationMs) { return }
    await runTimedAnimation(durationMs: durationMs)
  }

  private func runTimedAnimation(durationMs: Double) async {
    let started = Date()
    while true {
      let elapsed = max(0.0, Date().timeIntervalSince(started) * 1000.0)
      lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.sampleTimedAnimation(elapsedMs: elapsed)))
      await publishPulses(lastPulses)
      if elapsed >= durationMs { return }
      await sleepPoseStep(originalPoseStepMs)
    }
  }

  private func runPulseRamp(target: [Int], durationMs: Double) async {
    let start = lastPulses
    let started = Date()
    while true {
      let elapsed = max(0.0, Date().timeIntervalSince(started) * 1000.0)
      let amount = durationMs <= 0 ? 1.0 : min(1.0, elapsed / durationMs)
      var frame = Array(repeating: 1500, count: 18)
      for i in 0..<18 {
        frame[i] = Int((Double(start[i]) * (1.0 - amount)) + (Double(target[i]) * amount))
      }
      lastPulses = mergeActiveLegPulses(frame)
      await publishPulses(lastPulses)
      if elapsed >= durationMs { return }
      await sleepPoseStep(originalPoseStepMs)
    }
  }

  private func publishBlockRaisedRamp() async {
    let b = config.modes[5]
    // Durations divide by j.f7130i = the CURRENT mode's speed (block is not a
    // mode; f7161n/f7130i stay on the active mode), not the block row's.
    await runShapeRamp(radius: b.radius + 80, z: b.bodyLift + 100, corner: b.cornerAngle, elongation: b.elongation, durationMs: 800.0 / currentMode().speed)
  }

  private func publishBlockShapeRamp() async {
    await publishBlockRaisedRamp()
    let b = config.modes[5]
    await runShapeRamp(radius: b.radius, z: b.bodyLift, corner: b.cornerAngle, elongation: b.elongation, durationMs: 1200.0 / currentMode().speed)
  }

  private func publishSittingShapeRamp(_ m: ChicaConfig.ModeParams) async {
    await runShapeRamp(radius: m.radius, z: config.legSittingZ, corner: m.cornerAngle, elongation: m.elongation, durationMs: 1200.0 / m.speed)
  }

  private func publishCalibPoseRamp() async {
    let target = pulses(from: gaitEngine.calibrationPoseTargetPulses())
    await runPulseRamp(target: target, durationMs: 1200.0 / currentMode().speed)
  }

  // MARK: - Impulses

  private func ensureStandingForImpulse() async -> Bool {
    if activeWalk || lastWalk.active || hasSetTarget() { return false }
    block = false
    calibPosition = false
    if !relayEnabled { relayEnabled = true; await publishRelay(true) }
    if !standing { await enterStandPose(); standing = true }
    return true
  }

  private func runOriginalBounce() async {
    if !(await ensureStandingForImpulse()) { return }
    let duration = 168.0 / currentMode().speed
    for _ in 0..<2 {
      await runBodyZDeltaRamp(bodyZDelta: 10, durationMs: duration)
      await runBodyZDeltaRamp(bodyZDelta: -10, durationMs: duration / 2.0)
    }
  }

  private func runOriginalJump() async {
    if !(await ensureStandingForImpulse()) { return }
    let duration = 200.0 / currentMode().speed
    await runBodyZDeltaRamp(bodyZDelta: 18, durationMs: duration)
    await runBodyZDeltaRamp(bodyZDelta: 126, durationMs: duration / 3.0)
    await runBodyZDeltaRamp(bodyZDelta: -216, durationMs: duration / 3.0)
    await runBodyZDeltaRamp(bodyZDelta: 72, durationMs: duration)
  }

  private func runOriginalCalibrate() async {
    if originalMotionBusy() { return }
    if standing {
      await enterSitPose()
      standing = false
      relayEnabled = false
      await publishRelay(false)
    }
    _ = await readTelemetryTouches()
    if Task.isCancelled { return }
    let prevActive = activeOutputLegs
    activeOutputLegs = ChicaConst.allLegs
    defer { activeOutputLegs = prevActive }
    // Calibration starts with a fresh body origin and the mode's neutral feet.
    gaitEngine.beginCalibration()
    for pass in 0..<3 {
      lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.calibrationRaiseAll(deltaZ: 10)))
      await publishPulses(lastPulses)
      await sleepPoseStep(200)
      var contacted = Array(repeating: false, count: 6)
      while !Task.isCancelled {
        lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.calibrationCurrentPulses()))
        await publishPulses(lastPulses)
        await sleepPoseStep(pass == 0 ? 5 : 100)
        let t = await readTelemetryTouches()
        if Task.isCancelled { return }
        var allContacted = true
        for leg in ChicaConst.allLegs {
          // Contact is measured again on each poll, rather than latched.
          contacted[leg] = !t[leg].isNaN && t[leg] > 0.5
          if !contacted[leg] { allContacted = false }
        }
        if allContacted { break }
        gaitEngine.calibrationLowerUntouched(contacted: contacted.map { NSNumber(value: $0) }, deltaZ: -0.20000000298023224)
      }
      if Task.isCancelled { return }
    }
  }

  // MARK: - Modes

  private func currentMode() -> ChicaConfig.ModeParams {
    config.modes[min(max(mode, 0), 4)]
  }

  private func applyModeConfig() {
    let m = currentMode()
    if mode <= 3 { gait = clampGait(mode + 1) }
    gaitEngine.configureMode(withRadius: m.radius, cornerAngleDeg: m.cornerAngle, elongation: m.elongation, legSittingZ: config.legSittingZ, swingLift: m.stepLift, walkAnimFactor: m.animationFactor)
  }

  private func applyOriginalMode(_ requested: Int) async {
    let next = max(0, min(4, requested))
    if next == mode || originalMotionBusy() { return }
    if next == 4 { await applyOriginalQuadMode([1, 4]); return }
    let m = config.modes[next]
    let oldMode = mode
    let wasStanding = standing
    let restoreRelayOff = !relayEnabled

    // QUAD EXIT (original z0.o.i() i8==4 path). The original SITS, then
    // shape-ramps the previously-disabled legs OUT to the new mode geometry at
    // sitting z (h.f7099h = -40) over 700/quad-speed, re-enables all legs,
    // home-poses, and re-stands. The shape-ramp is a LINEAR lerp (no swing arc),
    // so the tucked legs (z = femurScale*120 + connZ = 110) descend smoothly to
    // neutral. Without it, the home pose's lift arc sweeps those legs UP past
    // z=150 then down -> the "not smooth" quad->hex snap. Only quad->* needs
    // this; hex->hex re-seats via the plain home pose below.
    if oldMode == 4 {
      if wasStanding {
        await enterSitPose()
        standing = false
      }
      relayEnabled = true
      await publishRelay(true)
      // Re-enable ALL legs BEFORE the shape-ramp (original z0.o.i does a(null)
      // before C()). TWO masks must open: (1) engine IK mask via configureMode —
      // else inverseKinematics skips legs {1,4}, leaving stale angles so they
      // collapse fully tucked under the body once visible; (2) the output mask —
      // else the disabled legs freeze at their tuck pulses through the ramp
      // (invisible "wait") and the later flip snaps them to hex. Both open ->
      // the descent is IK-solved and actually sent -> smooth.
      gaitEngine.configureMode(withRadius: m.radius, cornerAngleDeg: m.cornerAngle, elongation: m.elongation, legSittingZ: config.legSittingZ, swingLift: m.stepLift, walkAnimFactor: m.animationFactor)
      activeOutputLegs = ChicaConst.allLegs
      // Disabled legs = the two NOT in the quad active set. (Do NOT reuse
      // activeLegComplement: it maps disabled->active, so feeding it the active
      // set returns a bogus 4-leg mix that ramps two active legs and misses two,
      // splitting the active reconfiguration across both phases — the observed
      // disabled-leg snap + off sequence.)
      let disabledLegs = (0..<6).filter { !quadrupedActiveLegs.contains($0) }
      // Re-seat every foot from the current servo angles (forward kinematics)
      // before ramping. The parked disabled legs stayed frozen at their tuck
      // angles while the body drifted forward during the walk, so their stored
      // world position is stale (~travelled distance behind the body). FK snaps
      // them back under the CURRENT body; without it the shape-ramp starts from
      // that stale spot and sweeps the whole distance -> malformed away from
      // origin. Mirrors the original z0.a.a(null) -> z0.j.a() on re-enable.
      gaitEngine.reseatFeetFromForwardKinematics()
      await runShapeRampForLegs(legs: disabledLegs, radius: m.radius, z: config.legSittingZ, corner: m.cornerAngle, elongation: m.elongation, durationMs: 700.0 / config.modes[4].speed)
    }

    mode = next
    activeOutputLegs = ChicaConst.allLegs
    if mode <= 3 { gait = mode + 1 }
    gaitEngine.configureMode(withRadius: m.radius, cornerAngleDeg: m.cornerAngle, elongation: m.elongation, legSittingZ: config.legSittingZ, swingLift: m.stepLift, walkAnimFactor: m.animationFactor)
    if standing {
      await runBodyZRamp(bodyZ: m.bodyLift, durationMs: 400.0 / m.speed)
    }
    // Change the mode/body lift first; power home temporarily, then restore.
    if restoreRelayOff {
      relayEnabled = true
      await publishRelay(true)
    }
    await enterOriginalHomePose()
    if restoreRelayOff {
      relayEnabled = false
      await publishRelay(false)
    }
    if oldMode == 4 && wasStanding {
      await enterStandPose()
      standing = true
    }
  }

  private func applyOriginalQuadMode(_ disabledLegs: [Int]) async {
    if mode == 4 || originalMotionBusy() { return }
    let oldMode = mode
    let oldRelay = relayEnabled
    let oldStanding = standing
    let oldModeParams = currentMode()

    if oldStanding { await enterSitPose(); standing = false }
    relayEnabled = true
    await publishRelay(true)

    let quadDisabledZ = (config.femurScale * 120.0) + config.legConnectionZ
    // Original tucks the disabled legs at STANDARD radius+40 (h.f7104n[0]),
    // not the outgoing mode's radius; duration uses the outgoing speed.
    await runShapeRampForLegs(legs: disabledLegs, radius: config.modes[0].radius + 40, z: quadDisabledZ, corner: 80, elongation: 1.0, durationMs: 700.0 / oldModeParams.speed)

    quadrupedActiveLegs = activeLegComplement(disabledLegs)
    activeOutputLegs = quadrupedActiveLegs
    let quadMode = config.modes[4]
    mode = 4
    gaitEngine.configureMode(radius: quadMode.radius, cornerAngleDeg: quadMode.cornerAngle, elongation: quadMode.elongation, legSittingZ: config.legSittingZ, swingLift: quadMode.stepLift, walkAnimFactor: quadMode.animationFactor, legs: quadrupedActiveLegs.map { NSNumber(value: $0) })
    if oldMode <= 3 { gait = oldMode + 1 }

    await enterOriginalHomePose()

    if oldStanding {
      await enterStandPose(); standing = true
    } else if !oldRelay {
      relayEnabled = false
      await publishRelay(false)
    }
  }

  // MARK: - Walk

  private func applyWalkCommand(_ command: String) async {
    guard let values = parseTriple(command) else { record("invalid walk \(command)"); return }
    let startingWalkWorker = walkTask == nil
    let previousWalkMode = walkModeIndex
    let previousAnimation = animation
    let wasStanding = standing
    let lateralOrTurn = values.0
    lastWalk = WalkCommandState(
      forward: clampUnit(values.1),
      strafe: crab ? clampUnit(lateralOrTurn) : 0,
      turn: crab ? 0 : clampUnit(lateralOrTurn))
    animation = Int(values.2)
    walkModeIndex = updatedWalkModeIndex(for: command)
    if !startingWalkWorker {
      walkModeIndex = previousWalkMode
      animation = previousAnimation
    }
    relayEnabled = true
    await publishRelay(true)
    if !wasStanding {
      await enterStandPose()
      standing = true
    }
    activeWalk = true
    pendingWalkClear = false
    pendingStopStep = false
    block = false
    if startingWalkWorker {
      gaitEngine.beginWalkSession()
      filteredWalk = lerpWalk(from: WalkCommandState(), to: lastWalk, amount: 0.05)
      lastStepMillis = monotonicMilliseconds()
      walkStepCount = 0
      startWalkWorker()
    }
  }

  private func startWalkWorker() {
    if walkTask != nil { return }
    let preserveKeptQuadrupedPose = keep && mode == 4
    walkTask = Task { @MainActor in
      while !Task.isCancelled {
        let shouldContinue = await stepOriginalGait()
        if !shouldContinue {
          break
        }
        await sleepPoseStep(originalPoseStepMs)
      }
      if !Task.isCancelled && !preserveKeptQuadrupedPose {
        await publishOriginalLayerFade()
      }
      walkTask = nil
    }
  }

  private func stopWalking(cancelTask: Bool) {
    activeWalk = false
    if cancelTask {
      walkTask?.cancel(); walkTask = nil
      pendingWalkClear = false
      pendingStopStep = false
    }
    lastWalk = WalkCommandState()
    filteredWalk = WalkCommandState()
    walkStepCount = 0
  }

  private func stepOriginalGait() async -> Bool {
    let now = monotonicMilliseconds()
    let rawDtMs = min(Double(now >= lastStepMillis ? now - lastStepMillis : 0), ChicaConst.maxStepDtMs)
    var dtMs = rawDtMs * currentMode().speed
    let transitioningToStop = pendingWalkClear
    let walking = activeWalk || transitioningToStop
    let stopping = pendingStopStep
    // walkclear releases the busy flag immediately. Its old gait task still
    // drains its target/anchors if a sit or torque command changes posture.
    guard walking || stopping else { return false }

    dtMs = originalFrameDt(stepCount: walkStepCount, measuredDtMs: dtMs)
    lastStepMillis = now
    let allowGait = walking || walkMagnitude(filteredWalk) > originalStopVectorThreshold
    lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.step(
      withGait: gaitForMode(), animation: animation,
      forward: filteredWalk.forward, strafe: filteredWalk.strafe, turn: filteredWalk.turn,
      deltaMs: dtMs, allowNewAnchors: allowGait)))
    walkStepCount += 1
    await publishPulses(lastPulses)

    if transitioningToStop {
      pendingWalkClear = false
      pendingStopStep = true
    } else if walking {
      filteredWalk = lerpWalk(from: filteredWalk, to: lastWalk, amount: 0.05)
    } else if allowGait {
      filteredWalk = scaleWalk(filteredWalk, by: 0.9)
    } else if !gaitEngine.hasActiveWalkAnchors() {
      pendingStopStep = false
      pendingWalkClear = false
      filteredWalk = WalkCommandState()
      walkStepCount = 0
      return false
    }
    return true
  }

  private func requestOriginalWalkStop(logTargetNull: Bool) {
    if logTargetNull { record("walkclear_target_null") }
    if standing && relayEnabled && walkTask != nil {
      pendingStopStep = false
      pendingWalkClear = true
      activeWalk = false
      lastWalk = WalkCommandState()
      return
    }
    pendingStopStep = false
    pendingWalkClear = false
    activeWalk = false
    lastWalk = WalkCommandState()
    filteredWalk = WalkCommandState()
    walkStepCount = 0
  }

  private func publishOriginalLayerFade() async {
    let context = gaitEngine.beginLayerFadeContext()
    var magnitude = localSetTargetMagnitude((0..<6).map { (context[$0] as! NSNumber).doubleValue })
    var previous = monotonicMilliseconds()
    while !Task.isCancelled && magnitude > 0.05000000074505806 {
      let now = monotonicMilliseconds()
      let amount = currentMode().speed * 0.1 * Double(now >= previous ? now - previous : 0)
      if amount >= magnitude { break }
      lastPulses = mergeActiveLegPulses(
        pulses(from: gaitEngine.stepLayerFadeContext(context, amount: amount)))
      await publishPulses(lastPulses)
      await sleepPoseStep(originalPoseStepMs)
      magnitude = localSetTargetMagnitude((0..<6).map { (context[$0] as! NSNumber).doubleValue })
      previous = now
    }
    if Task.isCancelled { return }
    lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.finishLayerFadeContext(context)))
    await publishPulses(lastPulses)
  }

  // MARK: - Set pose

  private func applySetCommand(_ command: String) {
    if command.hasPrefix("setclear") { resetSetControls(); return }
    guard let values = parsePair(command) else { record("invalid set \(command)"); return }
    // Each set command replaces the entire 6-DOF target, matching the original
    // (`f7072h = new p3.a(x,y,z,u,v,w)`), which zeroes every axis the command
    // doesn't drive. primary=(x,y), tertiary=(z,u), secondary=(v,w).
    var px = 0.0, py = 0.0, sx = 0.0, sy = 0.0, tx = 0.0, ty = 0.0
    if command.hasPrefix("setxy:") {
      let e = clampStickPair(-values.0, values.1)
      px = e.0; py = e.1
    } else if command.hasPrefix("setzu:") {
      // z = second value, u = first value (original: z=v8, u=v3). z/u live in
      // separate xyz/uvw vectors, so clamp each axis independently.
      tx = clampUnit(values.1)
      ty = clampUnit(values.0)
    } else if command.hasPrefix("setvw:") {
      let f = clampStickPair(-values.0, -values.1)
      sx = f.0; sy = f.1
    } else if command.hasPrefix("setxyvw:") || command.hasPrefix("setdive:") {
      let e = clampStickPair(-values.0, values.1)
      px = e.0; py = e.1
      let f = clampStickPair(values.0, values.1)
      sx = f.0; sy = f.1
    } else if command.hasPrefix("setrotate:") {
      let e = clampStickPair(-values.0, values.1)
      px = e.0; py = e.1
    } else {
      record("invalid set \(command)"); return
    }
    lastPrimaryX = px; lastPrimaryY = py
    lastSecondaryX = sx; lastSecondaryY = sy
    lastTertiaryX = tx; lastTertiaryY = ty
    setPoseTargetActive = true
    // An active worker keeps its B/G routine and dive/flex form. New commands
    // only replace the shared target, matching Android and the original APK.
    if !setWorkerRunning {
      if command.hasPrefix("setdive:") {
        setSweepMode = 1
      } else if command.hasPrefix("setrotate:") {
        setSweepMode = 2
      } else {
        setSweepMode = 0
      }
    }
    if isQuadOutputMode() {
      // Original quad path only re-emits the current staged frame here (no new
      // set-pose step); the heartbeat is already flushing lastPulses. The quad
      // 2.5 set mode then runs its own blend-scheduled worker.
      if isQuad25SetMode() { startQuadSetWorker() }
    } else {
      startSetWorker()
    }
  }

  private func resetSetControls() {
    setPoseTargetActive = false
    lastPrimaryX = 0; lastPrimaryY = 0; lastSecondaryX = 0; lastSecondaryY = 0
    lastTertiaryX = 0; lastTertiaryY = 0
    // Clearing the logical flag permits a new worker while the old one drains
    // its private target and velocity. It does not change the old routine.
    setWorkerRunning = false
  }

  private func approachSharedSetTarget(_ target: inout [Double]) {
    // Match the original multiplication/addition order of its 0.05 blend.
    let shared = [lastPrimaryX, lastPrimaryY, lastTertiaryX, lastTertiaryY, lastSecondaryX, lastSecondaryY]
    for i in 0..<6 { target[i] = shared[i] * 0.05 + 0.95 * target[i] }
  }

  private func localSetTargetMagnitude(_ target: [Double]) -> Double {
    let xyz = sqrt(target[0] * target[0] + target[1] * target[1] + target[2] * target[2])
    let uvw = sqrt(target[3] * target[3] + target[4] * target[4] + target[5] * target[5])
    return xyz + 4 * uvw
  }

  private func startSetWorker() {
    if setWorkerRunning { return }
    setWorkerRunning = true
    let sweepRoutine = setSweepMode != 0
    let id = UUID()
    setTasks[id] = Task { @MainActor in
      defer {
        setTasks.removeValue(forKey: id)
        // A completed old worker clears the shared flag, just like the APK.
        // Cancelled tasks belong to a stopped service, possibly since restarted.
        if !Task.isCancelled { setWorkerRunning = false }
      }
      if Task.isCancelled { return }
      let workerSweepMode = sweepRoutine ? (setSweepMode == 1 ? 1 : 2) : 0
      let keepStaticPose = keep
      var target = Array(repeating: 0.0, count: 6)
      let workerState = NSMutableArray(array: Array(repeating: NSNumber(value: 0.0), count: 7))
      var previous = monotonicMilliseconds()
      var hasLocalTarget = setPoseTargetActive
      if hasLocalTarget { approachSharedSetTarget(&target) }
      var hasPreviousTarget = false
      while !Task.isCancelled && (hasLocalTarget || hasPreviousTarget) {
        let now = monotonicMilliseconds()
        let dtMs = Double(now >= previous ? now - previous : 0) * currentMode().speed
        previous = now
        lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.stepSetWorker(
          state: workerState, target: target.map { NSNumber(value: $0) },
          sweepMode: workerSweepMode, deltaMs: dtMs)))
        await publishPulses(lastPulses)
        await sleepPoseStep(originalPoseStepMs)
        if Task.isCancelled { return }
        var fadeLayer = false
        if hasLocalTarget {
          hasPreviousTarget = true
          if setPoseTargetActive {
            approachSharedSetTarget(&target)
          } else {
            hasLocalTarget = false
          }
        } else if workerSweepMode != 0 {
          fadeLayer = true
          hasPreviousTarget = false
        } else if keepStaticPose {
          gaitEngine.keepSetPose()
          hasPreviousTarget = false
        } else {
          // Run B before decaying the local target by 0.9; fade below 0.01.
          target = target.map { $0 * 0.9 }
          if localSetTargetMagnitude(target) < 0.01 {
            fadeLayer = true
            hasPreviousTarget = false
          }
        }
        if fadeLayer { await publishOriginalLayerFade() }
      }
    }
  }

  private func startQuadSetWorker() {
    if setWorkerRunning { return }
    setWorkerRunning = true
    let id = UUID()
    setTasks[id] = Task { @MainActor in
      defer {
        setTasks.removeValue(forKey: id)
        if !Task.isCancelled { setWorkerRunning = false }
      }
      for i in 0..<ChicaConst.quadSet25StepMs.count {
        await sleepPoseStep(510)
        if Task.isCancelled || !relayEnabled || !standing || !isQuad25SetMode() { return }
        let blend = ChicaConst.quadSet25Blend[i]
        lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.stepSetPose(
          x: lastPrimaryX * blend, y: lastPrimaryY * blend, z: lastTertiaryX * blend, u: lastTertiaryY * blend,
          v: lastSecondaryX * blend, w: lastSecondaryY * blend, deltaMs: ChicaConst.quadSet25StepMs[i])))
        await publishPulses(lastPulses)
      }
    }
  }

  // MARK: - Level worker

  private func startLevelWorker() {
    if levelTask != nil { return }
    levelTask = Task { @MainActor in
      while !Task.isCancelled {
        if !(await stepOriginalLevelPose()) { levelTask = nil; level = false; return }
        await sleepPoseStep(originalPoseStepMs)
      }
      levelTask = nil
    }
  }

  private func stepOriginalLevelPose() async -> Bool {
    if level {
      // Self-leveling and manual set-pose both drive the same rotation layer
      // (layers[3]). If a manual pose is active, yield to it so the two workers
      // don't fight over u/v/w every tick (which shows up as jitter on z-w / u-v
      // / xy-uv while x-y stays smooth). Leveling resumes once the pose clears.
      if !setTasks.isEmpty || hasSetTarget() {
        return true
      }
      lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.applyLevelPose(x: orientationX, y: orientationY)))
      await publishPulses(lastPulses)
      return true
    }
    if gaitEngine.levelPoseMagnitude() > 0.1 {
      lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.decayLevelPose(factor: 0.98)))
      await publishPulses(lastPulses)
      return true
    }
    lastPulses = mergeActiveLegPulses(pulses(from: gaitEngine.decayLevelPose(factor: 0.0)))
    await publishPulses(lastPulses)
    return false
  }

  // MARK: - Output helpers

  private func mergeActiveLegPulses(_ frame: [Int]) -> [Int] {
    guard frame.count == 18 else { return lastPulses }
    if activeOutputLegs == ChicaConst.allLegs || activeOutputLegs.count >= 6 { return frame }
    var merged = lastPulses
    for leg in activeOutputLegs where leg >= 0 && leg < 6 {
      for pin in ChicaConst.servoPinsByLeg[leg] { merged[pin] = frame[pin] }
    }
    return merged
  }

  private func publishRelay(_ enabled: Bool) async {
    do {
      try await hardware.setRelay(enabled, configuredAs: config.hardwareIO.relay)
      hardwareConnected = true; hardwareState = "connected"
    } catch {
      hardwareConnected = false; hardwareState = "write failed"
      record("relay write failed: \(error.localizedDescription)")
    }
  }

  private func publishPulses(_ pulses: [Int]) async {
    await hardware.stageServoPulses(pulses)
  }

  // MARK: - Telemetry

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { @MainActor [self] in
      var heartbeatCount = 0
      var communicatedHeartbeats = 0
      var windowStart = monotonicMilliseconds()
      var lastHeartbeat = monotonicMilliseconds()
      while !Task.isCancelled {
        await sleepPoseStep(1)
        let now = monotonicMilliseconds()
        if now >= lastHeartbeat && now - lastHeartbeat > 7 {
          do {
            var communicated = try await hardware.flushServoPulses()
            if heartbeatCount % 2 == 0 {
              let telemetry = try await hardware.readTelemetry(configuredAs: config.hardwareIO)
              voltage = blend(voltage, telemetry.voltage)
              current = blend(current, telemetry.current)
              legTouches = telemetry.legTouches
              communicated = true
            }
            if communicated {
              communicatedHeartbeats += 1
              // Board just came up after booting without it → restart once so the
              // service reinitializes with the hardware present.
              if !hardwareConnected && autoRestartOnConnect {
                autoRestartOnConnect = false
                Task { @MainActor [weak self] in await self?.restartService() }
              }
              hardwareConnected = true
              hardwareState = "connected"
            }
            heartbeatCount += 1
            lastHeartbeat = now
            updateWarnings()
          } catch {
            voltage = .nan; current = .nan
            legTouches = Array(repeating: .nan, count: 6)
            hardwareConnected = false; hardwareState = "poll failed"
            lastHeartbeat = now
          }
        }
        if now >= windowStart && now - windowStart > 1_000 {
          bps = communicatedHeartbeats
          heartbeatCount = 0
          communicatedHeartbeats = 0
          windowStart = now
          // Drop the connection-type readout when no client line arrived recently.
          if Date().timeIntervalSince(lastClientLineAt) > 3 { connectionType = "-" }
        }
        debugTick += 1
        if debugTick % 8 == 0 { updateDebugInfo() }
      }
    }
  }

  private func updateDebugInfo() {
    let mode = ["std", "race", "off", "cust", "quad"][min(max(self.mode, 0), 4)]
    debugInfo = String(
      format: "walk:%d set:%d lvl:%d busy:%d | aWalk:%d stand:%d relay:%d | fW:%.2f anch:%d pend:%d%d | mode:%@",
      walkTask != nil ? 1 : 0, setWorkerRunning ? 1 : 0, levelTask != nil ? 1 : 0, busy ? 1 : 0,
      activeWalk ? 1 : 0, standing ? 1 : 0, relayEnabled ? 1 : 0,
      walkMagnitude(filteredWalk), gaitEngine.hasActiveWalkAnchors() ? 1 : 0,
      pendingWalkClear ? 1 : 0, pendingStopStep ? 1 : 0, mode)
  }

  private func readTelemetryTouches() async -> [Double] {
    if let t = try? await hardware.readTelemetry(configuredAs: config.hardwareIO) { return t.legTouches }
    return Array(repeating: Double.nan, count: 6)
  }

  private func blend(_ previous: Double, _ next: Double) -> Double {
    if previous.isNaN || next.isNaN { return next }
    return (previous * 0.8) + (next * 0.2)
  }

  private func updateWarnings() {
    let now = Date()
    if current.isNaN || !relayEnabled {
      voltageWarnSince = now; voltageCutSince = now; currentWarnSince = now; currentCutSince = now
      voltageWarning = false; currentWarning = false
      cutoffTorquePending = false
      return
    }
    if current < config.currentWarningLevel { currentWarnSince = now }
    if current < config.currentCutoffLevel { currentCutSince = now }
    if voltage > config.voltageWarningLevel { voltageWarnSince = now }
    if voltage > config.voltageCutoffLevel { voltageCutSince = now }
    currentWarning = now.timeIntervalSince(currentWarnSince) > config.currentWarningDuration
    voltageWarning = now.timeIntervalSince(voltageWarnSince) > config.voltageWarningDuration
    let currentCutoff = now.timeIntervalSince(currentCutSince) > config.currentWarningDuration
    let voltageCutoff = now.timeIntervalSince(voltageCutSince) > config.voltageWarningDuration
    if currentCutoff || voltageCutoff {
      // Original z0.d: f7069e = 6 (six beeps) and ENQUEUE the "torque" command,
      // which runs the full toggle path — sit first if standing, THEN relay
      // off — a graceful shutdown, not a hard relay cut. One command in flight
      // at a time (f7078o gate); retried every tick until the relay actually
      // drops. Relay-off resets the latch above.
      if !cutoffTorquePending || !busy {
        cutoffTorquePending = true
        beepCount = 6
        submitOriginalCommand("torque")
      }
    } else if config.voltageBeepCount > 0 && voltageWarning {
      beepCount = config.voltageBeepCount  // original: f7069e = h.D
    } else if config.currentBeepCount > 0 && currentWarning {
      beepCount = config.currentBeepCount  // original: f7069e = h.f7113w
    }
  }

  // Original z0.c TimerTask (100 ms): play beepCount tones at 200 ms spacing,
  // zero the counter, then hold 1 s so warning re-arms read as a beep PATTERN
  // (N beeps / second) rather than a continuous tone.
  private func startBeeperWorker() {
    guard beeperTask == nil else { return }
    beeperTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        // The synthesized beeper mirrors the robot's physical buzzer, so it only
        // sounds while hardware is actually connected. Without a board (e.g. the
        // failed-open path, which sets beepCount = 6), there is no buzzer to
        // sound — otherwise every launch beeps six times at nothing.
        var count = self.hardwareConnected ? self.beepCount : 0
        if !self.hardwareConnected { self.beepCount = 0 }
        while count > 0 && !Task.isCancelled {
          self.beeper.beep()
          try? await Task.sleep(nanoseconds: 200_000_000)
          count -= 1
          if count == 0 {
            self.beepCount = 0
            try? await Task.sleep(nanoseconds: 1_000_000_000)
          }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  // MARK: - Orientation (CoreMotion -> level layer)

  private func startOrientationUpdates() {
    #if canImport(CoreMotion)
    guard motionManager.isDeviceMotionAvailable else { return }
    motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
    motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      guard let self, let g = motion?.gravity else { return }
      // Reproduce the original orientation pipeline as closely as iOS allows.
      // The Android server fused TYPE_GRAVITY + magnetometer through
      // SensorManager.getRotationMatrix/getOrientation, then published
      // setOrientationVector(-roll, pitch, -azimuth). Self-leveling consumes only
      // roll & pitch, and in getOrientation those are
      //   pitch = asin(-A.y), roll = atan2(-A.x, A.z)
      // where A is the gravity-sensor "up" unit vector (magnetometer only drives
      // azimuth, which leveling ignores). CoreMotion's gravity uses the same
      // device axes but points toward earth, so the up vector A = -gravity.
      let ax = -g.x
      let ay = -g.y
      let az = -g.z
      let pitch = asin(max(-1.0, min(1.0, -ay)))
      let roll = atan2(-ax, az)
      self.orientationX = -roll
      self.orientationY = pitch
    }
    #endif
  }

  private func stopOrientationUpdates() {
    #if canImport(CoreMotion)
    motionManager.stopDeviceMotionUpdates()
    #endif
  }

  // MARK: - Small helpers

  private func hasSetTarget() -> Bool {
    lastPrimaryX != 0 || lastPrimaryY != 0 || lastSecondaryX != 0 || lastSecondaryY != 0
      || lastTertiaryX != 0 || lastTertiaryY != 0
  }

  private func updatedWalkModeIndex(for command: String) -> Int {
    if command.hasPrefix("walk3:") { return 5 }
    if command.hasPrefix("walk25:") { return 9 }
    if command.hasPrefix("walk2:") { return 6 }
    if command.hasPrefix("walk15:") { return 8 }
    if command.hasPrefix("walk1:") { return 7 }
    if command.hasPrefix("walkwave:") { return 10 }
    return walkModeIndex
  }

  private func gaitForMode() -> Int {
    // Quad uses the dedicated Quad gait (apk id 20): legs 0,2,3,5 swing in a
    // quad amble, legs 1,4 never swing. Without this, quad falls back to the
    // walk-style gait (Tripod) which flails 4 legs in a 6-leg pattern.
    if mode == 4 { return 20 }
    if (5...10).contains(walkModeIndex) { return walkModeIndex }
    return clampGait(gait)
  }

  private func clampGait(_ value: Int) -> Int { min(4, max(1, value)) }

  private func isQuadOutputMode() -> Bool {
    activeOutputLegs != ChicaConst.allLegs && activeOutputLegs.count < 6
  }

  private func isQuad25SetMode() -> Bool {
    quadrupedActiveLegs == [1, 0, 3, 4]
  }

  private func parseTriple(_ command: String) -> (Double, Double, Double)? {
    let parts = command.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let values = parts[1].split(separator: ",", omittingEmptySubsequences: false)
    // Validate the first three fields in place. Dropping malformed fields can
    // turn an invalid command into a different valid movement command.
    guard values.count >= 3,
          let first = Double(values[0].trimmingCharacters(in: .whitespaces)),
          let second = Double(values[1].trimmingCharacters(in: .whitespaces)),
          values[2].range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil,
          let style = Int32(values[2]) else { return nil }
    return (first, second, Double(style))
  }

  private func parsePair(_ command: String) -> (Double, Double)? {
    let parts = command.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let values = parts[1].split(separator: ",", omittingEmptySubsequences: false)
    guard values.count >= 2,
          let first = Double(values[0].trimmingCharacters(in: .whitespaces)),
          let second = Double(values[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    return (first, second)
  }

  private func parseQuadDisabledLegs(_ command: String) -> [Int]? {
    guard let colon = command.firstIndex(of: ":") else { return nil }
    let rest = command[command.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: false)
    // Use the first pair verbatim, including duplicates, and ignore extras.
    // Invalid input is safely rejected, matching the Android reconstruction.
    guard rest.count >= 2,
          rest[0].range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil,
          rest[1].range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil,
          let a = Int(rest[0]), let b = Int(rest[1]),
          (0..<6).contains(a), (0..<6).contains(b) else { return nil }
    return [a, b]
  }

  private func activeLegComplement(_ disabledLegs: [Int]) -> [Int] {
    ChicaConst.originalActiveOrder.filter { !disabledLegs.contains($0) }
  }

  private func originalFrameDt(stepCount: Int, measuredDtMs: Double) -> Double {
    stepCount == 0 ? 0.0 : measuredDtMs
  }

  private func sleepPoseStep(_ millis: Double) async {
    if millis < 1 { return }
    try? await Task.sleep(nanoseconds: UInt64(millis * 1_000_000))
  }

  private func lerpWalk(from: WalkCommandState, to: WalkCommandState, amount: Double) -> WalkCommandState {
    WalkCommandState(forward: lerp(from.forward, to.forward, amount),
                     strafe: lerp(from.strafe, to.strafe, amount),
                     turn: lerp(from.turn, to.turn, amount))
  }

  private func scaleWalk(_ v: WalkCommandState, by scale: Double) -> WalkCommandState {
    WalkCommandState(forward: v.forward * scale, strafe: v.strafe * scale, turn: v.turn * scale)
  }

  private func walkMagnitude(_ v: WalkCommandState) -> Double {
    sqrt((v.forward * v.forward) + (v.strafe * v.strafe) + (v.turn * v.turn))
  }

  private func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    ((1.0 - amount) * from) + (to * amount)
  }

  private func clampUnit(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    return min(1, max(-1, value))
  }

  private func clampStickPair(_ first: Double, _ second: Double) -> (Double, Double) {
    let magnitude = sqrt((first * first) + (second * second))
    if magnitude > 1 { return (first / magnitude, second / magnitude) }
    return (first, second)
  }

  private func pulses(from numbers: [NSNumber]) -> [Int] {
    let values = numbers.map(\.intValue)
    if values.count == 18 { return values }
    return Array(values.prefix(18)) + Array(repeating: 1500, count: max(0, 18 - values.count))
  }

  private func record(_ message: String) {
    log.insert(LogEntry(message: message), at: 0)
    if log.count > 80 { log.removeLast(log.count - 80) }
  }

  private func localIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = ptr.pointee
      guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: interface.ifa_name)
      guard name == "en0" || name.hasPrefix("bridge") || name.hasPrefix("pdp") else { continue }
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                  &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
      address = String(cString: hostname)
      if name == "en0" { break }
    }
    return address
  }
}

enum ChicaPorts {
  // Raw line-based TCP (legacy / fallback). Unchanged from the original server.
  static let tcp: UInt16 = 18711
  // Primary transport: same line protocol carried over WebSocket text frames.
  static let webSocket: UInt16 = 18710
}

enum ChicaConst {
  // Cap on a single gait/pose step's measured dt. The original runs its motion
  // workers on dedicated threads with a precise ~10ms sleep, so dt never exceeds
  // ~10-12ms. On iOS the workers are MainActor Tasks that can be scheduled late
  // under contention; without a cap a stalled frame feeds a huge dt into the
  // engine and the gait lurches/snaps (most visible resuming a walk right after a
  // stop). Clamping keeps per-frame advance bounded and matches the original in
  // the normal (unstalled) case.
  static let maxStepDtMs = 16.0
  static let allLegs = [0, 3, 1, 4, 2, 5]
  static let originalActiveOrder = [5, 2, 1, 0, 3, 4]
  static let standLeftTripod = [0, 4, 2]
  static let standRightTripod = [3, 1, 5]
  static let servoPinsByLeg = [
    [15, 16, 17], [9, 10, 11], [3, 4, 5],
    [12, 13, 14], [6, 7, 8], [0, 1, 2],
  ]
  static let quadSet25StepMs = [215.2, 423.2, 419.2, 414.4, 412.8]
  static let quadSet25Blend = [0.0975, 0.142625, 0.18549375, 0.2262190625, 0.264908109375]
  static let idleStatus = "BPS=  0|V=---|I=---|IP=0.0.0.0|LEGS=------|FLAGS=000000100"
}

final class ChicaClientSession {
  var ackCount = 0
}

final class ChicaControlServer {
  var initialLine: (() async -> String)?
  var process: ((String, ChicaClientSession) async -> String?)?
  var onLog: ((String) -> Void)?
  var onState: ((String) -> Void)?

  private let port: UInt16
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "chica.control.server")
  private var stopped = false
  private var restartPending = false

  init(port: UInt16) { self.port = port }

  func start() throws {
    stopped = false
    try startListener()
  }

  private func startListener() throws {
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    tcpOptions.enableKeepalive = true
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    // Advertise over Bonjour so iOS reliably grants the Local Network permission
    // (a bare TCP listener may never trigger the prompt, silently blocking LAN
    // clients). The Chica client itself discovers by scanning the subnet, but the
    // advertisement is what unblocks inbound connections.
    listener.service = NWListener.Service(name: "AsteriskServer", type: "_chicaserver._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.onLog?("server \(state)")
      switch state {
      case .setup:
        self.onState?("starting")
      case .waiting(let error):
        self.onState?("waiting: \(error.localizedDescription)")
      case .ready:
        self.onState?("listening")
      case .failed(let error):
        // The Bonjour-advertised listener can go defunct on a network change or
        // app backgrounding (NWError -65569). It does not recover on its own, so
        // tear it down and bring a fresh one up — otherwise the client silently
        // can't reach the server.
        self.onState?("failed: \(error.localizedDescription)")
        self.scheduleRestart()
      case .cancelled:
        self.onState?(self.stopped ? "stopped" : "restarting")
      @unknown default:
        self.onState?("unknown")
      }
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  private func scheduleRestart() {
    guard !stopped, !restartPending else { return }
    restartPending = true
    listener?.cancel()
    listener = nil
    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, !self.stopped else { return }
      self.restartPending = false
      do { try self.startListener() }
      catch {
        self.onLog?("control listener restart failed: \(error.localizedDescription)")
        self.scheduleRestart()
      }
    }
  }

  func stop() {
    stopped = true
    listener?.cancel()
    listener = nil
  }

  private func handle(_ connection: NWConnection) {
    let session = ChicaClientSession()
    onLog?("client accepted \(connection.endpoint)")
    connection.start(queue: queue)
    Task {
      let status = await initialLine?() ?? "ready:"
      send(status + "\n", on: connection)
      receiveLoop(connection: connection, buffer: "", session: session)
    }
  }

  private func receiveLoop(connection: NWConnection, buffer: String, session: ChicaClientSession) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        self.onLog?("client receive failed: \(error.localizedDescription)")
        connection.cancel()
        return
      }
      var nextBuffer = buffer
      if let data, !data.isEmpty {
        nextBuffer += String(data: data, encoding: .utf8) ?? ""
        let parts = nextBuffer.components(separatedBy: "\n")
        nextBuffer = parts.last ?? ""
        for line in parts.dropLast() {
          Task {
            guard let reply = await self.process?(line, session) else {
              connection.cancel()
              return
            }
            self.send(reply + "\n", on: connection)
          }
        }
      }
      if isComplete {
        connection.cancel()
      } else {
        self.receiveLoop(connection: connection, buffer: nextBuffer, session: session)
      }
    }
  }

  private func send(_ text: String, on connection: NWConnection) {
    connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
      if let error { self?.onLog?("client send failed: \(error.localizedDescription)") }
    })
  }
}

// Primary control transport. Carries the exact same line protocol as
// ChicaControlServer, but each command/reply is one WebSocket text frame
// (no newline framing required). The initial "ready:" status is pushed as the
// first frame on connect, mirroring the TCP handshake.
final class ChicaWebSocketServer {
  var initialLine: (() async -> String)?
  var process: ((String, ChicaClientSession) async -> String?)?
  var onLog: ((String) -> Void)?
  var onState: ((String) -> Void)?

  private let port: UInt16
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "chica.ws.server")
  private var stopped = false
  private var restartPending = false

  init(port: UInt16) { self.port = port }

  func start() throws {
    stopped = false
    try startListener()
  }

  private func startListener() throws {
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    tcpOptions.enableKeepalive = true
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.allowLocalEndpointReuse = true
    parameters.includePeerToPeer = true
    let wsOptions = NWProtocolWebSocket.Options()
    wsOptions.autoReplyPing = true
    parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    listener.service = NWListener.Service(name: "AsteriskServer", type: "_chicaserver-ws._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      self.onLog?("ws server \(state)")
      switch state {
      case .setup: self.onState?("starting")
      case .waiting(let error): self.onState?("waiting: \(error.localizedDescription)")
      case .ready: self.onState?("listening")
      case .failed(let error):
        // Recover from a defunct listener (network change / backgrounding), same
        // as the TCP server — otherwise WebSocket clients silently can't connect.
        self.onState?("failed: \(error.localizedDescription)")
        self.scheduleRestart()
      case .cancelled: self.onState?(self.stopped ? "stopped" : "restarting")
      @unknown default: self.onState?("unknown")
      }
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  private func scheduleRestart() {
    guard !stopped, !restartPending else { return }
    restartPending = true
    listener?.cancel()
    listener = nil
    queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, !self.stopped else { return }
      self.restartPending = false
      do { try self.startListener() }
      catch {
        self.onLog?("ws listener restart failed: \(error.localizedDescription)")
        self.scheduleRestart()
      }
    }
  }

  func stop() {
    stopped = true
    listener?.cancel()
    listener = nil
  }

  private func handle(_ connection: NWConnection) {
    let session = ChicaClientSession()
    onLog?("ws client accepted \(connection.endpoint)")
    connection.start(queue: queue)
    Task {
      let status = await initialLine?() ?? "ready:"
      sendText(status, on: connection)
      receiveLoop(connection: connection, session: session)
    }
  }

  private func receiveLoop(connection: NWConnection, session: ChicaClientSession) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self else { return }
      if let error {
        self.onLog?("ws receive failed: \(error.localizedDescription)")
        connection.cancel()
        return
      }
      if let context,
         let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
         metadata.opcode == .close {
        connection.cancel()
        return
      }
      if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
        // One frame is normally one command, but tolerate newline-batched frames.
        let lines = text.contains("\n") ? text.components(separatedBy: "\n") : [text]
        for raw in lines {
          if raw.isEmpty && lines.count > 1 { continue }
          Task {
            guard let reply = await self.process?(raw, session) else {
              connection.cancel()
              return
            }
            self.sendText(reply, on: connection)
          }
        }
      }
      self.receiveLoop(connection: connection, session: session)
    }
  }

  private func sendText(_ text: String, on connection: NWConnection) {
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "textFrame", metadata: [metadata])
    connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                    completion: .contentProcessed { [weak self] error in
      if let error { self?.onLog?("ws send failed: \(error.localizedDescription)") }
    })
  }
}

actor Servo2040TCPHardware {
  struct Telemetry {
    let voltage: Double
    let current: Double
    let legTouches: [Double]
  }

  private enum TelemetryField {
    case touch(Int, ChicaConfig.DigitalPin)
    case voltage(ChicaConfig.AnalogPin)
    case current(ChicaConfig.AnalogPin)

    var pin: ChicaConfig.Pin {
      switch self {
      case .touch(_, let input): return input.pin
      case .voltage(let input), .current(let input): return input.pin
      }
    }
  }

  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private var connection: NWConnection?
  private var stagedServoFrame = Data(repeating: 0, count: 39)
  private var hasStagedServoFrame = false

  init(host: String = "192.168.204.1", port: NWEndpoint.Port = 18712) {
    self.host = NWEndpoint.Host(host)
    self.port = port
  }

  func connect() async throws {
    if let connection, connection.state == .ready { return }
    connection?.cancel()
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    let newConnection = NWConnection(host: host, port: port, using: parameters)
    try await waitUntilReady(newConnection)
    connection = newConnection
  }

  func cancel() {
    connection?.cancel()
    connection = nil
  }

  func setRelay(_ enabled: Bool, configuredAs relay: ChicaConfig.DigitalPin?) async throws {
    guard let relay else { return }
    guard relay.pin.primaryBoard else { throw ChicaNetworkError.secondaryBoardUnsupported }
    try await send(Servo2040Frames.digitalOut(
      pin: relay.pin.number, enabled: enabled == relay.activeHigh))
  }

  func stageServoPulses(_ pulses: [Int]) {
    Servo2040Frames.writeServoPulses(pulses, to: &stagedServoFrame)
    hasStagedServoFrame = true
  }

  func flushServoPulses() async throws -> Bool {
    guard hasStagedServoFrame else { return false }
    try await send(stagedServoFrame)
    return true
  }

  func readTelemetry(configuredAs io: ChicaConfig.HardwareIO) async throws -> Telemetry {
    var fields: [TelemetryField] = []
    for (index, input) in io.touches.enumerated() {
      if let input, input.pin.primaryBoard { fields.append(.touch(index, input)) }
    }
    if let voltage = io.voltage, voltage.pin.primaryBoard { fields.append(.voltage(voltage)) }
    if let current = io.current, current.pin.primaryBoard { fields.append(.current(current)) }
    guard !fields.isEmpty else {
      return Telemetry(
        voltage: .nan, current: .nan, legTouches: Array(repeating: .nan, count: 6))
    }

    var request = Data()
    for field in fields {
      request.append(Servo2040Frames.get(pin: field.pin.number, count: 1))
    }
    try await send(request)
    let reply = try await receiveExact(count: fields.count * 5)
    var touches = Array(repeating: Double.nan, count: 6)
    var voltage = Double.nan
    var current = Double.nan
    for (index, field) in fields.enumerated() {
      let offset = index * 5
      guard reply[offset] == 0xC7,
            Int(reply[offset + 1]) == field.pin.number,
            reply[offset + 2] == 1 else { throw ChicaNetworkError.badReply }
      let raw = Int(reply[offset + 3]) | (Int(reply[offset + 4]) << 7)
      switch field {
      case .touch(let leg, let input):
        let normalized = Double(raw) / 1024.0
        touches[leg] = input.activeHigh ? normalized : 1.0 - normalized
      case .voltage(let input):
        voltage = calibratedAnalog(raw: raw, input: input)
          ?? (Double(raw) / 310.29998779296875)
      case .current(let input):
        current = calibratedAnalog(raw: raw, input: input)
          ?? ((Double(raw) - 512.0) * 0.08139999955892563)
      }
    }
    return Telemetry(voltage: voltage, current: current, legTouches: touches)
  }

  private func calibratedAnalog(raw: Int, input: ChicaConfig.AnalogPin) -> Double? {
    guard input.oneVoltage != input.zeroVoltage else { return nil }
    let pinVoltage = Double(raw) * 3.3 / 1024.0
    return (pinVoltage - input.zeroVoltage) / (input.oneVoltage - input.zeroVoltage)
  }

  private func send(_ data: Data) async throws {
    try await connect()
    guard let connection else { throw ChicaNetworkError.notConnected }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  private func receiveExact(count: Int) async throws -> Data {
    var result = Data()
    while result.count < count {
      guard let connection else { throw ChicaNetworkError.notConnected }
      let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, isComplete, error in
          if let error { continuation.resume(throwing: error) }
          else if let data, !data.isEmpty { continuation.resume(returning: data) }
          else if isComplete { continuation.resume(throwing: ChicaNetworkError.closed) }
          else { continuation.resume(returning: Data()) }
        }
      }
      result.append(chunk)
    }
    return result
  }

  private func waitUntilReady(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let gate = VoidContinuationGate(continuation)
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume(.success(()))
        case .failed(let error):
          gate.resume(.failure(error))
        case .waiting(let error):
          // Fail fast instead of letting NWConnection sit in .waiting forever
          // when the Servo2040 link is absent; callers retry lazily on next send.
          gate.resume(.failure(error))
        case .cancelled:
          gate.resume(.failure(ChicaNetworkError.closed))
        default:
          break
        }
      }
      connection.start(queue: .global(qos: .userInitiated))
    }
  }
}

final class VoidContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  private let continuation: CheckedContinuation<Void, Error>

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func resume(_ result: Result<Void, Error>) {
    lock.lock(); defer { lock.unlock() }
    guard !resumed else { return }
    resumed = true
    switch result {
    case .success: continuation.resume()
    case .failure(let error): continuation.resume(throwing: error)
    }
  }
}

enum Servo2040Frames {
  static func servoPulses(_ pulses: [Int]) -> Data {
    var frame = Data(repeating: 0, count: 39)
    writeServoPulses(pulses, to: &frame)
    return frame
  }

  static func writeServoPulses(_ pulses: [Int], to frame: inout Data) {
    if frame.count != 39 { frame = Data(repeating: 0, count: 39) }
    frame[0] = 0xD3
    frame[1] = 0x00
    frame[2] = 0x12
    for index in 0..<18 {
      let pulse = pulses.indices.contains(index) ? pulses[index] : 1500
      let offset = 3 + (index * 2)
      frame[offset] = UInt8(pulse & 0x7F)
      frame[offset + 1] = UInt8((pulse >> 7) & 0x7F)
    }
  }

  static func digitalOut(pin: Int, enabled: Bool) -> Data {
    var frame = Data([0xD3, UInt8(pin & 0x7F), 0x01])
    appendU14(enabled ? 1 : 0, to: &frame)
    return frame
  }

  static func get(pin: Int, count: Int) -> Data {
    Data([0xC7, UInt8(pin & 0x7F), UInt8(count & 0x7F)])
  }

  private static func appendU14(_ value: Int, to data: inout Data) {
    data.append(UInt8(value & 0x7F))
    data.append(UInt8((value >> 7) & 0x7F))
  }
}

enum ChicaNetworkError: Error {
  case notConnected
  case closed
  case badReply
  case secondaryBoardUnsupported
}

// Plays a short beep tone on the device. The original `beep` command (and the
// voltage/current warnings) drive the robot/server buzzer; on iOS we synthesize
// an equivalent tone. A PCM WAV is generated at launch and played via
// AVAudioPlayer on a `.playback` session so it sounds even when the ring/silent
// switch is set to silent (AudioServices system sounds are suppressed there).
final class ChicaBeeper {
  #if canImport(AVFoundation)
  private var player: AVAudioPlayer?
  #endif

  init() {
    prepare()
  }

  private func prepare() {
    #if canImport(AVFoundation)
    guard let data = ChicaBeeper.makeBeepWav(frequency: 880, durationMs: 160, sampleRate: 44_100) else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .duckOthers])
      try AVAudioSession.sharedInstance().setActive(true, options: [])
      let made = try AVAudioPlayer(data: data, fileTypeHint: "wav")
      made.volume = 1.0
      made.prepareToPlay()
      player = made
    } catch {
      player = nil
    }
    #endif
  }

  func beep() {
    #if canImport(AVFoundation)
    guard let player else { return }
    // Re-activate in case another app/session deactivated ours, then restart.
    try? AVAudioSession.sharedInstance().setActive(true, options: [])
    player.currentTime = 0
    player.play()
    #endif
  }

  // 16-bit mono PCM WAV with a short raised-cosine fade to avoid clicks.
  private static func makeBeepWav(frequency: Double, durationMs: Double, sampleRate: Double) -> Data? {
    let frameCount = Int(sampleRate * durationMs / 1000.0)
    guard frameCount > 0 else { return nil }
    let fade = max(1, Int(sampleRate * 0.005))  // 5 ms fade in/out
    var samples = [Int16](repeating: 0, count: frameCount)
    let twoPiF = 2.0 * Double.pi * frequency / sampleRate
    for i in 0..<frameCount {
      var amp = 0.5 * sin(twoPiF * Double(i))
      if i < fade { amp *= Double(i) / Double(fade) }
      if i > frameCount - fade { amp *= Double(frameCount - i) / Double(fade) }
      samples[i] = Int16(max(-1.0, min(1.0, amp)) * 32767.0)
    }

    let dataSize = frameCount * 2
    var data = Data()
    func appendLE32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func appendLE16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8))
    appendLE32(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    appendLE32(16)                 // PCM fmt chunk size
    appendLE16(1)                  // PCM
    appendLE16(1)                  // mono
    appendLE32(UInt32(sampleRate))
    appendLE32(UInt32(sampleRate) * 2)  // byte rate
    appendLE16(2)                  // block align
    appendLE16(16)                 // bits per sample
    data.append(contentsOf: Array("data".utf8))
    appendLE32(UInt32(dataSize))
    for sample in samples { appendLE16(UInt16(bitPattern: sample)) }
    return data
  }
}
