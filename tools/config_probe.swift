import Foundation

@main
enum ConfigProbe {
  static func main() {
    let stock = ChicaConfigStore.defaultConfigText
    precondition(ChicaConfig.isValid(stock))
    let parsed = ChicaConfig.parse(stock)
    precondition(parsed.flatPins == [
      15, 16, 17, 9, 10, 11, 3, 4, 5,
      12, 13, 14, 6, 7, 8, 0, 1, 2,
    ])
    precondition(parsed.flatCalibration.count == 36)
    precondition(parsed.servoPins[0][0] == ChicaConfig.Pin(number: 15, primaryBoard: true))
    precondition(parsed.modes[0].radius == 220)
    precondition(parsed.modes[2].bodyLift == 60)
    precondition(parsed.modes[2].verticalCorrection == 120)
    precondition(parsed.modes[4].speed == 0.8)
    precondition(parsed.coxaAttach == [-8, 0, 8, -8, 0, 8])
    precondition(parsed.femurScale == 1)
    precondition(parsed.touchPins.map { $0?.pin.number } == [23, 21, 19, 22, 20, 18])
    precondition(parsed.touchPins.allSatisfy { $0?.activeHigh == true })
    precondition(parsed.relayPin == ChicaConfig.DigitalPin(
      pin: ChicaConfig.Pin(number: 26, primaryBoard: true), activeHigh: true))
    precondition(parsed.currentPin?.pin.number == 24)
    precondition(parsed.voltagePin?.pin.number == 25)
    precondition(parsed.currentBeepCount == 3 && parsed.voltageBeepCount == 3)

    let custom = stock.replacingOccurrences(of: "MODE_CUSTOM    220", with: "MODE_CUSTOM    245")
    precondition(ChicaConfig.parse(custom).modes[3].radius == 245)
    let activeLow = stock
      .replacingOccurrences(of: "TS_L1 P23 1", with: "TS_L1 P27 0")
      .replacingOccurrences(of: "RELAY P26 1", with: "RELAY P28 0")
      .replacingOccurrences(of: "CUR P24 0 0", with: "CUR P29 0.5 2.5")
    let customIO = ChicaConfig.parse(activeLow)
    precondition(customIO.touchPins[0] == ChicaConfig.DigitalPin(
      pin: ChicaConfig.Pin(number: 27, primaryBoard: true), activeHigh: false))
    precondition(customIO.relayPin == ChicaConfig.DigitalPin(
      pin: ChicaConfig.Pin(number: 28, primaryBoard: true), activeHigh: false))
    precondition(customIO.currentPin?.zeroVoltage == 0.5)
    precondition(customIO.currentPin?.oneVoltage == 2.5)
    precondition(!ChicaConfig.isValid(stock.replacingOccurrences(of: "MODE_RACE      210", with: "MODE_RACE      bad")))
    print("config parser exact: servo, I/O, warning, mode, and geometry fields validated")
  }
}
