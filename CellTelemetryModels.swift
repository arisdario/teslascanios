import Foundation

enum CellTelemetryFormat: Equatable {
    case classicSXMux6F2
    case model3YMux401
    case palladium
    case unknown
}

struct ValidatedCellTelemetry: Equatable {
    var format: CellTelemetryFormat = .unknown

    /// BMS brick/cell-group number 1...96 mapped to volts.
    var cellVoltages: [Int: Double] = [:]

    /// Temperature channel 1...32 mapped to degrees Celsius.
    var moduleTemps: [Int: Double] = [:]

    var averageVoltage: Double = 0
    var deltaVoltage: Double = 0
    var isValidated = false
    var receivedAt: Date?

    var minimumVoltage: Double? {
        cellVoltages.values.min()
    }

    var maximumVoltage: Double? {
        cellVoltages.values.max()
    }

    var averageTemperature: Double? {
        guard !moduleTemps.isEmpty else {
            return nil
        }

        return moduleTemps.values.reduce(0, +)
            / Double(moduleTemps.count)
    }

    var minimumTemperature: Double? {
        moduleTemps.values.min()
    }

    var maximumTemperature: Double? {
        moduleTemps.values.max()
    }

    var isComplete: Bool {
        cellVoltages.count == 96 &&
        moduleTemps.count == 32
    }
}
