import Foundation

/// Bit-level decode parameters for one signal. Most signals in this project use
/// Intel (little-endian) bit numbering, matching the DBC-derived entries; a
/// smaller set use Motorola (big-endian) packing instead.
struct CANDecode: Codable {
    let startBit: Int
    let bitLength: Int
    let signed: Bool
    let scale: Double
    let offset: Double
    let note: String?

    var endianness: String = "intel"
    var enumMap: [String: Int]? = nil

    func value(from bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty, bytes.count <= 8 else {
            return nil
        }

        let totalBits = bytes.count * 8

        guard startBit >= 0,
              bitLength > 0,
              bitLength <= 64,
              startBit + bitLength <= totalBits
        else {
            return nil
        }

        let mask: UInt64 =
            bitLength == 64
            ? UInt64.max
            : (UInt64(1) << UInt64(bitLength)) - 1

        let raw: UInt64

        switch endianness.lowercased() {
        case "motorola":
            var combined: UInt64 = 0

            for byte in bytes {
                combined = (combined << 8) | UInt64(byte)
            }

            let shift = totalBits - startBit - bitLength

            guard shift >= 0 else {
                return nil
            }

            raw = (combined >> UInt64(shift)) & mask

        default:
            // Intel/little-endian extraction.
            // byte 0 occupies bits 0...7, byte 1 bits 8...15, etc.
            var combined: UInt64 = 0

            for (index, byte) in bytes.enumerated() {
                combined |= UInt64(byte) << UInt64(index * 8)
            }

            raw = (combined >> UInt64(startBit)) & mask
        }

        if signed,
           bitLength < 64,
           (raw & (UInt64(1) << UInt64(bitLength - 1))) != 0 {

            let signExtensionMask = ~mask
            let signedRaw = Int64(bitPattern: raw | signExtensionMask)

            return Double(signedRaw) * scale + offset
        }

        if signed, bitLength == 64 {
            return Double(Int64(bitPattern: raw)) * scale + offset
        }

        return Double(raw) * scale + offset
    }

    /// Resolves an enum-valued signal back to its text label.
    func label(for bytes: [UInt8]) -> String? {
        guard let map = enumMap,
              let decoded = value(from: bytes)
        else {
            return nil
        }

        let rawInt = Int(decoded.rounded())

        return map.first {
            $0.value == rawInt
        }?.key
    }
}

/// One Tesla CAN signal definition loaded from JSON.
struct CANSignal: Codable, Identifiable {
    var id: String {
        "\(idHex)-\(name)"
    }

    let packetId: Int?
    let idHex: String
    let name: String
    let unit: String
    let numBits: Int?
    let reportedBy: String
    let comment: String
    let calculatedInApp: Bool
    let accuracy: Int?
    let accuracyComment: String
    let source: String
    let classicModelS: Bool
    let decode: CANDecode?

    var canID: UInt32? {
        UInt32(idHex, radix: 16)
    }
}

enum SignalCategory: String, CaseIterable {
    case battery = "Battery"
    case drivetrain = "Drivetrain"
    case hvac = "HVAC"
    case vehicle = "Vehicle"
    case other = "Other"
}

extension CANSignal {
    var category: SignalCategory {
        let normalizedName = name.lowercased()
        let normalizedReporter = reportedBy.lowercased()

        let overrides: [String: SignalCategory] = [
            "hv power": .battery
        ]

        if let forcedCategory = overrides[normalizedName] {
            return forcedCategory
        }

        let batteryKeywords = [
            "cell",
            "soc",
            "charge",
            "discharge",
            "energy",
            "range",
            "regen",
            "battery"
        ]

        if normalizedReporter == "bms"
            || normalizedReporter == "dc-dc"
            || batteryKeywords.contains(where: normalizedName.contains) {
            return .battery
        }

        let vehicleKeywords = [
            "steering",
            "brake",
            "gear",
            "cruise",
            "hold state",
            "odometer",
            "speed",
            "door",
            "handle",
            "charge port",
            "stopping condition"
        ]

        if vehicleKeywords.contains(where: normalizedName.contains) {
            return .vehicle
        }

        let drivetrainKeywords = [
            "torque",
            "motor",
            "rpm",
            "stator",
            "inverter",
            "pedal",
            "drive ratio",
            "wrpm",
            "mech power",
            "dissipation",
            "efficiency",
            "hp"
        ]

        if normalizedReporter.contains("drive unit")
            || drivetrainKeywords.contains(where: normalizedName.contains) {
            return .drivetrain
        }

        if normalizedReporter == "hvac"
            || normalizedName.contains("hvac")
            || normalizedName.contains("louver")
            || normalizedName.contains("temp") {
            return .hvac
        }

        return .other
    }

    var isBatteryModule: Bool {
        idHex.uppercased() == "6F2"
    }

    var isVehicleConfig: Bool {
        let configurationIDs = ["318", "31A", "83", "319"]

        return configurationIDs.contains(idHex.uppercased())
            && reportedBy == "GTW"
            && source.contains("leaked")
    }
}

/// Loads and decodes the bundled Tesla CAN signal table.
final class TeslaSignalTable {
    typealias DecodedValue = (
        value: Double,
        unit: String,
        note: String?,
        label: String?
    )

    static let shared = TeslaSignalTable()

    let all: [CANSignal]
    let decodable: [CANSignal]

    private let byID: [UInt32: [CANSignal]]

    private init() {
        guard let url = Bundle.main.url(
            forResource: "tesla_signals",
            withExtension: "json"
        ) else {
            print(
                """
                ⚠️ tesla_signals.json not found in bundle.
                Check Target Membership and Copy Bundle Resources.
                """
            )

            all = []
            decodable = []
            byID = [:]
            return
        }

        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(
                [CANSignal].self,
                from: data
              )
        else {
            print(
                """
                ⚠️ tesla_signals.json was found but could not be decoded.
                """
            )

            all = []
            decodable = []
            byID = [:]
            return
        }

        all = loaded
        decodable = loaded.filter {
            $0.decode != nil
        }

        byID = Dictionary(
            grouping: decodable,
            by: {
                $0.canID ?? 0
            }
        )
    }

    func signals(for canID: UInt32) -> [CANSignal] {
        byID[canID] ?? []
    }

    /// Decodes every signal for which a CAN frame is currently available.
    func decodeAll(
        from frames: [UInt32: [UInt8]]
    ) -> [String: DecodedValue] {
        var result: [String: DecodedValue] = [:]

        for signal in all {
            guard let canID = signal.canID,
                  let bytes = frames[canID]
            else {
                continue
            }

            let overrideKey = "\(signal.idHex)-\(signal.name)"

            if let userDecode =
                UserDecodeStore.shared.overrides[overrideKey],
               let value = userDecode.value(from: bytes) {

                result[signal.name] = (
                    value: value,
                    unit: signal.unit,
                    note: userDecode.note
                        ?? "User-calibrated via Signal Detective",
                    label: userDecode.label(for: bytes)
                )

                continue
            }

            guard let decode = signal.decode,
                  let value = decode.value(from: bytes)
            else {
                continue
            }

            result[signal.name] = (
                value: value,
                unit: signal.unit,
                note: decode.note,
                label: decode.label(for: bytes)
            )
        }

        // Merge in signals the user has self-mapped via Action Scanner / Map
        // Unknown Signal. This is the ONE place decodeAll is assembled, so
        // every consumer (Dashboard, custom views, anywhere else) picks these
        // up automatically without needing to know CustomSignalStore exists.
        // Custom names never collide with sheet names in practice, but if they
        // do, the sheet signal wins (custom entries added first, sheet below
        // would need `continue` — instead we simply don't overwrite here).
        for custom in CustomSignalStore.shared.signals {
            guard result[custom.name] == nil,
                  let canID = custom.canID,
                  let bytes = frames[canID],
                  let value = custom.decode.value(from: bytes)
            else { continue }
            result[custom.name] = (
                value: value,
                unit: custom.unit,
                note: custom.decode.note ?? "Self-mapped via Action Scanner",
                label: custom.decode.label(for: bytes)
            )
        }

        addDerivedBMSEnergyValues(to: &result)

        return result
    }

    /// Adds energy values derived from the correctly decoded 0x382 fields.
    ///
    /// This does not decode the raw payload again. It uses the normal JSON-driven
    /// values already placed in the result dictionary.
    private func addDerivedBMSEnergyValues(
        to result: inout [String: DecodedValue]
    ) {
        guard let nominalFullEntry = findValue(
            in: result,
            names: [
                "Nominal full pack",
                "Nominal full",
                "Nominal Full Pack"
            ]
        ),
        let nominalRemainingEntry = findValue(
            in: result,
            names: [
                "Nominal remaining",
                "Nominal energy remaining",
                "Nominal Remaining"
            ]
        ),
        let bufferEntry = findValue(
            in: result,
            names: [
                "Energy buffer",
                "Buffer",
                "Energy Buffer"
            ]
        )
        else {
            return
        }

        let nominalFull = nominalFullEntry.value
        let nominalRemaining = nominalRemainingEntry.value
        let buffer = bufferEntry.value

        // Reject physically impossible decoded values.
        guard nominalFull > 0,
              nominalFull <= 120,
              nominalRemaining >= 0,
              nominalRemaining <= 120,
              buffer >= 0,
              buffer <= 30
        else {
            print(
                """
                ⚠️ Invalid 0x382 energy values:
                nominalFull: \(nominalFull)
                nominalRemaining: \(nominalRemaining)
                buffer: \(buffer)
                """
            )

            return
        }

        let usableFull = nominalFull - buffer
        let usableRemaining = nominalRemaining - buffer

        guard usableFull > 0 else {
            return
        }

        /*
         A small negative usable-remaining value can appear close to empty due
         to rounding. Clamp the displayed value to zero.
         */
        let clampedUsableRemaining = max(
            0,
            min(usableRemaining, usableFull)
        )

        let calculatedSOC = min(
            100,
            max(
                0,
                clampedUsableRemaining / usableFull * 100
            )
        )

        result["Usable full pack"] = (
            value: usableFull,
            unit: "kWh",
            note:
                "Calculated as nominal full pack minus the energy buffer.",
            label: nil
        )

        result["Usable energy remaining"] = (
            value: clampedUsableRemaining,
            unit: "kWh",
            note:
                "Calculated as nominal remaining minus the energy buffer.",
            label: nil
        )

        /*
         Do not name this simply "SOC", because that could overwrite the real
         Tesla SOC UI signal or another decoded SOC value.
         */
        result["Calculated energy SOC"] = (
            value: calculatedSOC,
            unit: "%",
            note:
                "Calculated from usable remaining divided by usable full pack.",
            label: nil
        )
    }

    /// Finds a decoded value while supporting small naming differences in JSON.
    private func findValue(
        in result: [String: DecodedValue],
        names: [String]
    ) -> DecodedValue? {
        for name in names {
            if let entry = result[name] {
                return entry
            }
        }

        let normalizedNames = Set(
            names.map {
                $0
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        )

        for (name, entry) in result {
            let normalizedName = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if normalizedNames.contains(normalizedName) {
                return entry
            }
        }

        return nil
    }
}

/// Values calculated from decoded CAN signals.
enum TeslaDerived {
    /// Battery power in kW = voltage × current ÷ 1000.
    static func batteryPowerKW(
        from frames: [UInt32: [UInt8]]
    ) -> Double? {
        let signals = TeslaSignalTable.shared.decodeAll(
            from: frames
        )

        guard let voltage =
                findValue(
                    in: signals,
                    names: [
                        "Battery voltage",
                        "Battery voltage (0x102)",
                        "Battery voltage (0x126)"
                    ]
                ),
              let current =
                findValue(
                    in: signals,
                    names: [
                        "Battery current",
                        "HV battery current"
                    ]
                )
        else {
            return nil
        }

        return voltage * current / 1_000
    }

    private static func findValue(
        in signals: [String: TeslaSignalTable.DecodedValue],
        names: [String]
    ) -> Double? {
        for name in names {
            if let value = signals[name]?.value {
                return value
            }
        }

        let normalizedNames = Set(
            names.map {
                $0
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
            }
        )

        for (name, entry) in signals {
            let normalizedName = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if normalizedNames.contains(normalizedName) {
                return entry.value
            }
        }

        return nil
    }
}
