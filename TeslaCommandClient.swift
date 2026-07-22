import Foundation

/// Sends vehicle commands (vent/close windows, flash lights, honk, lock, climate, etc.)
///
/// WHY THIS ISN'T A CAN WRITE: everything else in this project only *reads* the CAN
/// bus, which is safe — you can't break anything by listening. Actuating things like
/// windows or locks over CAN means writing UDS/proprietary commands to body-control
/// ECUs, and those commands are NOT reliably publicly documented for the Model S the
/// way the read-only telemetry in the spreadsheet is. Tools built by people who do
/// this seriously (e.g. CANserver) deliberately stay read-only for exactly that
/// reason — a malformed write can trip fault codes or actuate something unexpectedly.
///
/// The supported, safe way to actuate the car from your own app is Tesla's official
/// Fleet API (requires registering as a Tesla developer, OAuth, and — for commands —
/// a "vehicle command protocol" signing key pair enrolled with the car). This class
/// is a thin wrapper around that HTTP API, not the CAN bus.
///
/// Docs: https://developer.tesla.com/docs/fleet-api
final class TeslaCommandClient {
    private let accessToken: String
    private let vehicleID: String
    /// Region-specific base URL Tesla assigns your account (e.g. "https://fleet-api.prd.na.vn.cloud.tesla.com")
    private let baseURL: URL

    init(accessToken: String, vehicleID: String, baseURL: URL) {
        self.accessToken = accessToken
        self.vehicleID = vehicleID
        self.baseURL = baseURL
    }

    enum Command: String {
        case windowControl = "window_control" // body: {"command": "vent"|"close", ...}
        case honkHorn = "honk_horn"
        case flashLights = "flash_lights"
        case lockDoors = "door_lock"
        case unlockDoors = "door_unlock"
        case startClimate = "auto_conditioning_start"
        case stopClimate = "auto_conditioning_stop"
        case setTemperature = "set_temps"
    }

    /// Fires a vehicle command. Most commands take no body; window_control needs
    /// {"command": "vent"|"close", "lat": 0, "lon": 0}, set_temps needs driver/passenger temps.
    func send(_ command: Command, body: [String: Any] = [:]) async throws {
        let url = baseURL
            .appendingPathComponent("api/1/vehicles")
            .appendingPathComponent(vehicleID)
            .appendingPathComponent("command")
            .appendingPathComponent(command.rawValue)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "TeslaCommandClient", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                           userInfo: [NSLocalizedDescriptionKey: text])
        }
    }

    func ventWindows() async throws {
        try await send(.windowControl, body: ["command": "vent", "lat": 0, "lon": 0])
    }

    func closeWindows() async throws {
        try await send(.windowControl, body: ["command": "close", "lat": 0, "lon": 0])
    }

    func honkHorn() async throws { try await send(.honkHorn) }
    func flashLights() async throws { try await send(.flashLights) }
    func lockDoors() async throws { try await send(.lockDoors) }
    func unlockDoors() async throws { try await send(.unlockDoors) }
    func startClimate() async throws { try await send(.startClimate) }
    func stopClimate() async throws { try await send(.stopClimate) }
}
