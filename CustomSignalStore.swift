import Foundation
import Combine

/// A signal you've discovered and named yourself — same shape as the bundled
/// reference signals, but for CAN IDs that weren't in the sheet at all.
struct CustomSignal: Codable, Identifiable {
    var id: String { "\(idHex)-\(name)" }
    let idHex: String
    let name: String
    let unit: String
    let decode: CANDecode
    let dateAdded: Date

    var canID: UInt32? { UInt32(idHex, radix: 16) }
}

/// Persists custom-mapped signals to disk, separately from both the bundled
/// reference table and the calibration overrides in UserDecodeStore (those
/// override an *existing* sheet entry; these create a brand new one).
final class CustomSignalStore: ObservableObject {
    static let shared = CustomSignalStore()

    @Published private(set) var signals: [CustomSignal] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom_signals.json")
    }

    private init() {
        load()
    }

    func add(_ signal: CustomSignal) {
        signals.removeAll { $0.idHex == signal.idHex && $0.name == signal.name }
        signals.append(signal)
        persist()
    }

    func remove(_ signal: CustomSignal) {
        signals.removeAll { $0.id == signal.id }
        persist()
    }

    /// CAN IDs already claimed by a custom mapping — used to keep them out of
    /// the "Unknown" list once you've named them.
    var mappedIDs: Set<UInt32> {
        Set(signals.compactMap { $0.canID })
    }

    func decodeAll(from frames: [UInt32: [UInt8]]) -> [String: (value: Double, unit: String)] {
        var result: [String: (Double, String)] = [:]
        for signal in signals {
            guard let id = signal.canID, let bytes = frames[id],
                  let value = signal.decode.value(from: bytes) else { continue }
            result[signal.name] = (value, signal.unit)
        }
        return result
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CustomSignal].self, from: data) else { return }
        signals = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        try? data.write(to: fileURL)
    }
}
