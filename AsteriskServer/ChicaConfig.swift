import Foundation

struct ChicaConfig {
  struct Pin: Equatable, Sendable {
    var number: Int
    var primaryBoard: Bool

    var token: String { "\(primaryBoard ? "P" : "S")\(number)" }
  }

  struct DigitalPin: Equatable, Sendable {
    var pin: Pin
    var activeHigh: Bool
  }

  struct AnalogPin: Equatable, Sendable {
    var pin: Pin
    var zeroVoltage: Double
    var oneVoltage: Double
  }

  struct HardwareIO: Sendable {
    var relay: DigitalPin?
    var touches: [DigitalPin?]
    var current: AnalogPin?
    var voltage: AnalogPin?
  }

  struct ModeParams: Sendable {
    var radius: Double
    var cornerAngle: Double
    var elongation: Double
    var bodyLift: Double
    var stepLift: Double
    var verticalCorrection: Double
    var speed: Double
    var animationFactor: Double
  }

  private static let modeNames = [
    "MODE_STANDARD", "MODE_RACE", "MODE_OFFROAD",
    "MODE_CUSTOM", "MODE_QUADRUPED", "MODE_BLOCK",
  ]
  private static let legNames = ["L1", "L2", "L3", "R1", "R2", "R3"]
  private static let touchNames = ["TS_L1", "TS_L2", "TS_L3", "TS_R1", "TS_R2", "TS_R3"]
  private static let defaultServoPins = [
    [15, 16, 17], [9, 10, 11], [3, 4, 5],
    [12, 13, 14], [6, 7, 8], [0, 1, 2],
  ].map { row in row.map { Pin(number: $0, primaryBoard: true) } }
  private static let defaultTouchPins = [23, 21, 19, 22, 20, 18].map {
    DigitalPin(pin: Pin(number: $0, primaryBoard: true), activeHigh: true)
  }

  var coxaLen = 43.0
  var femurLen = 80.0
  var tibiaLen = 134.0
  var l1ToR1 = 126.0
  var l1ToL3 = 167.0
  var l2ToR2 = 163.0
  var legConnectionZ = -10.0
  var legSittingZ = -40.0

  var modes = [
    ModeParams(radius: 220, cornerAngle: 55, elongation: 1.15, bodyLift: 40, stepLift: 40, verticalCorrection: 10, speed: 1.0, animationFactor: 1.0),
    ModeParams(radius: 210, cornerAngle: 55, elongation: 1.20, bodyLift: 35, stepLift: 30, verticalCorrection: 0, speed: 2.0, animationFactor: 0.0),
    ModeParams(radius: 230, cornerAngle: 55, elongation: 1.15, bodyLift: 60, stepLift: 99, verticalCorrection: 120, speed: 0.6, animationFactor: 1.0),
    ModeParams(radius: 220, cornerAngle: 55, elongation: 1.15, bodyLift: 40, stepLift: 40, verticalCorrection: 10, speed: 1.0, animationFactor: 1.0),
    ModeParams(radius: 220, cornerAngle: 60, elongation: 1.00, bodyLift: 45, stepLift: 35, verticalCorrection: 0, speed: 0.8, animationFactor: 1.0),
    ModeParams(radius: 185, cornerAngle: 30, elongation: 1.07, bodyLift: -40, stepLift: 80, verticalCorrection: 0, speed: 1.0, animationFactor: 1.0),
  ]

  var calibration = Array(
    repeating: Array(repeating: [2000, 1000], count: 3),
    count: 6)
  var servoPins = defaultServoPins
  var coxaAttach = [-8.0, 0.0, 8.0, -8.0, 0.0, 8.0]
  var femurAttach = 35.0
  var tibiaAttach = 68.0

  var touchPins: [DigitalPin?] = defaultTouchPins.map(Optional.some)
  var relayPin: DigitalPin? = DigitalPin(
    pin: Pin(number: 26, primaryBoard: true), activeHigh: true)
  var currentPin: AnalogPin? = AnalogPin(
    pin: Pin(number: 24, primaryBoard: true), zeroVoltage: 0, oneVoltage: 0)
  var voltagePin: AnalogPin? = AnalogPin(
    pin: Pin(number: 25, primaryBoard: true), zeroVoltage: 0, oneVoltage: 0)

  var voltageWarningDuration = 2.0
  var voltageWarningLevel = 6.4
  var voltageCutoffLevel = 6.0
  var voltageBeepCount = 3
  var currentWarningDuration = 2.0
  var currentWarningLevel = 8.0
  var currentCutoffLevel = 10.0
  var currentBeepCount = 3

  var femurScale: Double { ((femurLen + 80.0) / 2.0) / 80.0 }
  var flatCalibration: [Int] { calibration.flatMap { $0.flatMap { $0 } } }
  var flatPins: [Int] { servoPins.flatMap { $0.map(\.number) } }
  var hardwareIO: HardwareIO {
    HardwareIO(relay: relayPin, touches: touchPins, current: currentPin, voltage: voltagePin)
  }
  var summary: String {
    let touchText = touchPins.map { $0?.pin.token ?? "-" }.joined(separator: ",")
    let relayText = relayPin.map { "\($0.pin.token)/\($0.activeHigh ? "high" : "low")" } ?? "none"
    let modeText = modes.map { String(format: "%.0f", $0.radius) }.joined(separator: "/")
    return "servos=18 geometry=\(Int(coxaLen))/\(Int(femurLen))/\(Int(tibiaLen)) "
      + "modes=\(modeText) touch=\(touchText) relay=\(relayText) "
      + "adc=\(voltagePin?.pin.token ?? "-")/\(currentPin?.pin.token ?? "-")"
  }

  static func parse(_ text: String) -> ChicaConfig {
    var config = ChicaConfig()
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard let name = fields.first else { continue }

      if let modeIndex = modeNames.firstIndex(of: name), fields.count >= 9,
         let radius = Double(fields[1]), let corner = Double(fields[2]),
         let elongation = Double(fields[3]), let bodyLift = Double(fields[4]),
         let stepLift = Double(fields[5]), let vertical = Double(fields[6]),
         let speed = Double(fields[7]), let animation = Double(fields[8]) {
        config.modes[modeIndex] = ModeParams(
          radius: radius, cornerAngle: corner, elongation: elongation,
          bodyLift: bodyLift, stepLift: stepLift, verticalCorrection: vertical,
          speed: speed, animationFactor: animation)
        continue
      }

      if let servo = servoIndex(name), fields.count >= 4,
         let pin = parsePin(fields[1]), let low = Int(fields[2]), let high = Int(fields[3]) {
        config.servoPins[servo.leg][servo.joint] = pin
        config.calibration[servo.leg][servo.joint] = [low, high]
        continue
      }

      if let touch = touchNames.firstIndex(of: name), fields.count >= 2,
         let pin = parsePin(fields[1]) {
        config.touchPins[touch] = DigitalPin(
          pin: pin, activeHigh: fields.count < 3 || Int(fields[2]) != 0)
        continue
      }

      switch name {
      case "COXA_LEN": config.coxaLen = double(fields, 1) ?? config.coxaLen
      case "FEMUR_LEN": config.femurLen = double(fields, 1) ?? config.femurLen
      case "TIBIA_LEN": config.tibiaLen = double(fields, 1) ?? config.tibiaLen
      case "L1_TO_R1": config.l1ToR1 = double(fields, 1) ?? config.l1ToR1
      case "L1_TO_L3": config.l1ToL3 = double(fields, 1) ?? config.l1ToL3
      case "L2_TO_R2": config.l2ToR2 = double(fields, 1) ?? config.l2ToR2
      case "LEG_CONNECTION_Z": config.legConnectionZ = double(fields, 1) ?? config.legConnectionZ
      case "LEG_SITTING_Z": config.legSittingZ = double(fields, 1) ?? config.legSittingZ
      case "COXA_ATTACH_ANGLE":
        if let value = double(fields, 1) {
          config.coxaAttach = [value, 0, -value, value, 0, -value]
        }
      case "FEMUR_ATTACH_ANGLE": config.femurAttach = double(fields, 1) ?? config.femurAttach
      case "TIBIA_ATTACH_ANGLE": config.tibiaAttach = double(fields, 1) ?? config.tibiaAttach
      case "RELAY":
        if fields.count >= 2, let pin = parsePin(fields[1]) {
          config.relayPin = DigitalPin(
            pin: pin, activeHigh: fields.count < 3 || Int(fields[2]) != 0)
        }
      case "CUR":
        if fields.count >= 4, let pin = parsePin(fields[1]),
           let zero = Double(fields[2]), let one = Double(fields[3]) {
          config.currentPin = AnalogPin(pin: pin, zeroVoltage: zero, oneVoltage: one)
        }
      case "VOL":
        if fields.count >= 4, let pin = parsePin(fields[1]),
           let zero = Double(fields[2]), let one = Double(fields[3]) {
          config.voltagePin = AnalogPin(pin: pin, zeroVoltage: zero, oneVoltage: one)
        }
      case "WARN_VOL":
        if fields.count >= 5 {
          config.voltageWarningDuration = double(fields, 1) ?? config.voltageWarningDuration
          config.voltageWarningLevel = double(fields, 2) ?? config.voltageWarningLevel
          config.voltageCutoffLevel = double(fields, 3) ?? config.voltageCutoffLevel
          config.voltageBeepCount = Int(fields[4]) ?? config.voltageBeepCount
        }
      case "WARN_CUR":
        if fields.count >= 5 {
          config.currentWarningDuration = double(fields, 1) ?? config.currentWarningDuration
          config.currentWarningLevel = double(fields, 2) ?? config.currentWarningLevel
          config.currentCutoffLevel = double(fields, 3) ?? config.currentCutoffLevel
          config.currentBeepCount = Int(fields[4]) ?? config.currentBeepCount
        }
      default: break
      }
    }
    return config
  }

  static func isValid(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var deviceLines = 0
    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard fields.count >= 2 else { continue }
      if servoIndex(fields[0]) != nil {
        guard fields.count >= 4, parsePin(fields[1]) != nil,
              Int(fields[2]) != nil, Int(fields[3]) != nil else { return false }
        deviceLines += 1
      } else if fields[0].hasPrefix("TS_") {
        guard parsePin(fields[1]) != nil else { return false }
        deviceLines += 1
      } else if modeNames.contains(fields[0]) {
        guard fields.count >= 9, fields[1...8].allSatisfy({ Double($0) != nil }) else { return false }
      } else if [
        "COXA_LEN", "FEMUR_LEN", "TIBIA_LEN", "L1_TO_R1", "L1_TO_L3",
        "L2_TO_R2", "LEG_CONNECTION_Z", "LEG_SITTING_Z",
        "COXA_ATTACH_ANGLE", "FEMUR_ATTACH_ANGLE", "TIBIA_ATTACH_ANGLE",
      ].contains(fields[0]) {
        guard fields.count >= 2, Double(fields[1]) != nil else { return false }
      } else if fields[0] == "VOL" || fields[0] == "CUR" {
        guard fields.count >= 4, parsePin(fields[1]) != nil,
              Double(fields[2]) != nil, Double(fields[3]) != nil else { return false }
      } else if fields[0] == "RELAY" {
        guard parsePin(fields[1]) != nil else { return false }
      } else if fields[0] == "WARN_VOL" || fields[0] == "WARN_CUR" {
        guard fields.count >= 5, Double(fields[1]) != nil, Double(fields[2]) != nil,
              Double(fields[3]) != nil, Int(fields[4]) != nil else { return false }
      }
    }
    return deviceLines >= 18
  }

  private static func servoIndex(_ name: String) -> (leg: Int, joint: Int)? {
    guard name.count == 3, let jointDigit = name.last?.wholeNumberValue,
          (1...3).contains(jointDigit) else { return nil }
    let legName = String(name.prefix(2))
    guard let leg = legNames.firstIndex(of: legName) else { return nil }
    return (leg, jointDigit - 1)
  }

  private static func parsePin(_ token: String) -> Pin? {
    guard token.count >= 2, let prefix = token.first,
          prefix == "P" || prefix == "S", let number = Int(token.dropFirst()) else { return nil }
    return Pin(number: number, primaryBoard: prefix == "P")
  }

  private static func double(_ fields: [String], _ index: Int) -> Double? {
    guard fields.indices.contains(index) else { return nil }
    return Double(fields[index])
  }
}

enum ChicaConfigStore {
  private static let key = "chica.config"

  static func load() -> String {
    guard let saved = UserDefaults.standard.string(forKey: key), ChicaConfig.isValid(saved) else {
      return defaultConfigText
    }
    return saved
  }

  static func save(_ text: String) {
    UserDefaults.standard.set(text, forKey: key)
  }

  static let defaultConfigText = #"""
# Servo name, Servo2040 pin, pulse at -45 degrees, pulse at +45 degrees
L11 P15 2000 1000
L12 P16 2000 1000
L13 P17 2000 1000
L21 P09 2000 1000
L22 P10 2000 1000
L23 P11 2000 1000
L31 P03 2000 1000
L32 P04 2000 1000
L33 P05 2000 1000
R11 P12 2000 1000
R12 P13 2000 1000
R13 P14 2000 1000
R21 P06 2000 1000
R22 P07 2000 1000
R23 P08 2000 1000
R31 P00 2000 1000
R32 P01 2000 1000
R33 P02 2000 1000

TS_L1 P23 1
TS_L2 P21 1
TS_L3 P19 1
TS_R1 P22 1
TS_R2 P20 1
TS_R3 P18 1
CUR P24 0 0
VOL P25 0 0
WARN_CUR 2 8 10 3
WARN_VOL 2 6.4 6 3
RELAY P26 1

MODE_STANDARD  220 55 1.15  40 40  10 1.0 1.0
MODE_RACE      210 55 1.20  35 30   0 2.0 0.0
MODE_OFFROAD   230 55 1.15  60 99 120 0.6 1.0
MODE_CUSTOM    220 55 1.15  40 40  10 1.0 1.0
MODE_QUADRUPED 220 60 1.00  45 35   0 0.8 1.0
MODE_BLOCK     185 30 1.07 -40 80   0 1.0 1.0

COXA_LEN 43
FEMUR_LEN 80
TIBIA_LEN 134
L1_TO_R1 126
L1_TO_L3 167
L2_TO_R2 163
LEG_CONNECTION_Z -10
LEG_SITTING_Z -40
COXA_ATTACH_ANGLE -8
FEMUR_ATTACH_ANGLE 35
TIBIA_ATTACH_ANGLE 68
"""#
}
