import Foundation

final class BMS6F2Decoder {
    static let canID: UInt32 = 0x6F2

    private static let voltageScale = 0.000305
    private static let temperatureScale = 0.0122

    private let maximumFrameGap: TimeInterval = 5.0

    private var voltages = [Double?](repeating: nil, count: 96)
    private var temperatures = [Double?](repeating: nil, count: 32)

    private var receivedMask: UInt32 = 0
    private var lastFrameAt: Date?

    var receivedFrameCount: Int {
        receivedMask.nonzeroBitCount
    }

    func processFrame(
        payload: [UInt8],
        totalPackVoltage: Double?,
        timestamp: Date = Date()
    ) -> ValidatedCellTelemetry? {
        guard payload.count == 8 else {
            return nil
        }

        let index = payload[0]

        guard index < 32 else {
            return nil
        }

        if let lastFrameAt,
           timestamp.timeIntervalSince(lastFrameAt) > maximumFrameGap {
            reset()
        }

        lastFrameAt = timestamp

        let values = unpackValues(payload)

        if index < 24 {
            guard processVoltageFrame(
                index: index,
                values: values
            ) else {
                return nil
            }
        } else {
            guard processTemperatureFrame(
                index: index,
                values: values
            ) else {
                return nil
            }
        }

        receivedMask |= UInt32(1) << UInt32(index)

        return makePartialTelemetry(timestamp: timestamp)
    }

    private func processVoltageFrame(
        index: UInt8,
        values: (UInt16, UInt16, UInt16, UInt16)
    ) -> Bool {
        let decoded = [
            Double(values.0) * Self.voltageScale,
            Double(values.1) * Self.voltageScale,
            Double(values.2) * Self.voltageScale,
            Double(values.3) * Self.voltageScale
        ]

        guard decoded.allSatisfy({
            (2.0...4.5).contains($0)
        }) else {
            return false
        }

        let base = Int(index) * 4

        voltages[base] = decoded[0]
        voltages[base + 1] = decoded[1]
        voltages[base + 2] = decoded[2]
        voltages[base + 3] = decoded[3]

        return true
    }

    private func processTemperatureFrame(
        index: UInt8,
        values: (UInt16, UInt16, UInt16, UInt16)
    ) -> Bool {
        let decoded = [
            Double(signExtend14(values.0)) * Self.temperatureScale,
            Double(signExtend14(values.1)) * Self.temperatureScale,
            Double(signExtend14(values.2)) * Self.temperatureScale,
            Double(signExtend14(values.3)) * Self.temperatureScale
        ]

        guard decoded.allSatisfy({
            (-50.0...100.0).contains($0)
        }) else {
            return false
        }

        let base = (Int(index) - 24) * 4

        temperatures[base] = decoded[0]
        temperatures[base + 1] = decoded[1]
        temperatures[base + 2] = decoded[2]
        temperatures[base + 3] = decoded[3]

        return true
    }

    private func makePartialTelemetry(
        timestamp: Date
    ) -> ValidatedCellTelemetry? {
        var cellDictionary: [Int: Double] = [:]
        cellDictionary.reserveCapacity(96)

        for index in voltages.indices {
            if let voltage = voltages[index] {
                cellDictionary[index + 1] = voltage
            }
        }

        /*
         Do not publish anything until at least one voltage frame has arrived.
         One voltage mux frame supplies four cells.
         */
        guard !cellDictionary.isEmpty else {
            return nil
        }

        var temperatureDictionary: [Int: Double] = [:]
        temperatureDictionary.reserveCapacity(32)

        for index in temperatures.indices {
            if let temperature = temperatures[index] {
                temperatureDictionary[index + 1] = temperature
            }
        }

        let availableVoltages = Array(cellDictionary.values)

        guard let minimum = availableVoltages.min(),
              let maximum = availableVoltages.max()
        else {
            return nil
        }

        let sum = availableVoltages.reduce(0, +)

        return ValidatedCellTelemetry(
            format: .classicSXMux6F2,
            cellVoltages: cellDictionary,
            moduleTemps: temperatureDictionary,
            averageVoltage:
                sum / Double(availableVoltages.count),
            deltaVoltage: maximum - minimum,

            /*
             Only call the snapshot fully validated after all 96 voltage
             channels have arrived. Individual displayed values have already
             passed strict plausibility validation.
             */
            isValidated: cellDictionary.count == 96,
            receivedAt: timestamp
        )
    }

    private func unpackValues(
        _ payload: [UInt8]
    ) -> (UInt16, UInt16, UInt16, UInt16) {
        let packed =
            UInt64(payload[1]) |
            UInt64(payload[2]) << 8 |
            UInt64(payload[3]) << 16 |
            UInt64(payload[4]) << 24 |
            UInt64(payload[5]) << 32 |
            UInt64(payload[6]) << 40 |
            UInt64(payload[7]) << 48

        return (
            UInt16(packed & 0x3FFF),
            UInt16((packed >> 14) & 0x3FFF),
            UInt16((packed >> 28) & 0x3FFF),
            UInt16((packed >> 42) & 0x3FFF)
        )
    }

    private func signExtend14(_ raw: UInt16) -> Int {
        let value = Int(raw & 0x3FFF)

        return raw & 0x2000 != 0
            ? value - 0x4000
            : value
    }

    func reset() {
        voltages = [Double?](repeating: nil, count: 96)
        temperatures = [Double?](repeating: nil, count: 32)

        receivedMask = 0
        lastFrameAt = nil
    }
}
