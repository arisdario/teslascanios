import Foundation
import Combine

/// Persists decode calibrations you've confirmed yourself (via CalibrationView),
/// keyed the same way as the bundled table ("idHex-name"). These always take
/// precedence over the shipped `tesla_signals.json`, and survive app relaunch.
final class UserDecodeStore: ObservableObject {
    static let shared = UserDecodeStore()

    @Published private(set) var overrides: [String: CANDecode] = [:]

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("user_decodes.json")
    }

    private init() {
        load()
    }

    func save(key: String, decode: CANDecode) {
        overrides[key] = decode
        persist()
    }

    func remove(key: String) {
        overrides.removeValue(forKey: key)
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: CANDecode].self, from: data) else { return }
        overrides = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        try? data.write(to: fileURL)
    }
}
