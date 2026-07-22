import Foundation
import Combine

/// Computed dashboard metrics derived entirely from signals that actually
/// decode on this car (voltage, current, nominal pack energy, speed). Each
/// value returns nil when its inputs haven't been seen yet, so the UI can show
/// "—" rather than a fake zero.
enum Dashboard {

    /// Instantaneous battery power in kW. Positive = discharging (driving),
    /// negative = charging or regen. voltage(V) × current(A) / 1000.
    static func batteryPowerKW(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)]) -> Double? {
        guard let v = decoded["Battery voltage"]?.value, let a = decoded["Battery current"]?.value else { return nil }
        // Sheet convention: discharge current is negative in this signal, so flip
        // sign to make "driving" read positive, which is what people expect on a dash.
        return -(v * a) / 1000.0
    }

    /// Power currently going *into* propulsion (only when discharging).
    static func drivePowerKW(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)]) -> Double? {
        guard let p = batteryPowerKW(decoded) else { return nil }
        return p > 0 ? p : 0
    }

    /// Power currently being recovered (regen) or charged (only when negative).
    static func regenPowerKW(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)]) -> Double? {
        guard let p = batteryPowerKW(decoded) else { return nil }
        return p < 0 ? -p : 0
    }

    /// Usable energy remaining (kWh) = nominal remaining minus the buffer the
    /// car keeps below the displayed 0%.
    static func usableRemainingKWh(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)]) -> Double? {
        guard let remaining = decoded["Expected remaining"]?.value else { return nil }
        let buffer = decoded["Energy buffer"]?.value ?? 0
        return max(0, remaining - buffer)
    }

    /// Estimated range (in the user's distance unit) from usable energy and a
    /// consumption assumption. Since Rated/Typical range don't decode on this
    /// car, this is a MODEL, not the car's own number — it uses a configurable
    /// Wh-per-mile efficiency (default ~300 Wh/mi, typical for a Model S).
    static func estimatedRangeMiles(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)], whPerMile: Double) -> Double? {
        guard let usable = usableRemainingKWh(decoded), whPerMile > 0 else { return nil }
        return (usable * 1000.0) / whPerMile
    }

    /// Estimated range in kilometers. Same model as estimatedRangeMiles, but
    /// takes a Wh-per-km efficiency directly (default ~186 Wh/km for a Model S).
    static func estimatedRangeKm(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)], whPerKm: Double) -> Double? {
        guard let usable = usableRemainingKWh(decoded), whPerKm > 0 else { return nil }
        return (usable * 1000.0) / whPerKm
    }

    /// Instantaneous efficiency in Wh/mi. Only meaningful while actually moving;
    /// returns nil at a stop (division by ~zero speed would be garbage).
    static func instantEfficiencyWhPerMile(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)]) -> Double? {
        guard let powerKW = drivePowerKW(decoded), let speed = decoded["Speed"]?.value else { return nil }
        guard speed > 3 else { return nil } // below walking pace, instantaneous Wh/mi is meaningless
        // speed here is mph (per the DBC note on 0x116). Wh/mi = (kW*1000) / mph.
        return (powerKW * 1000.0) / speed
    }

    /// Battery degradation as a percentage lost vs. the pack's original design
    /// capacity. Needs the user to set their original capacity (varies by
    /// 60/70/85/90/100 kWh variant), so it's a comparison, not a guess.
    static func degradationPercent(_ decoded: [String: (value: Double, unit: String, note: String?, label: String?)], originalKWh: Double) -> Double? {
        guard let nominalFull = decoded["Nominal full pack"]?.value, originalKWh > 0, nominalFull > 0 else { return nil }
        let lost = (originalKWh - nominalFull) / originalKWh * 100.0
        return max(0, lost) // never show negative degradation
    }
}

/// Simple trip tracker: integrates battery power over time to accumulate energy
/// used and regenerated since you tapped "start trip." Persisted so a trip
/// survives app backgrounding, reset on demand.
final class TripTracker: ObservableObject {
    @Published var isActive = false
    @Published var energyUsedKWh: Double = 0      // net propulsion energy
    @Published var energyRegenKWh: Double = 0     // recovered via regen
    @Published var startDate: Date?

    private var lastSampleTime: Date?

    func start() {
        energyUsedKWh = 0
        energyRegenKWh = 0
        startDate = Date()
        lastSampleTime = Date()
        isActive = true
    }

    func stop() {
        isActive = false
        lastSampleTime = nil
    }

    /// Call on each new decode with the current battery power (kW, +driving/-regen).
    /// Integrates power × elapsed-time into kWh.
    func accumulate(powerKW: Double?) {
        guard isActive, let powerKW else { return }
        let now = Date()
        defer { lastSampleTime = now }
        guard let last = lastSampleTime else { return }
        let hours = now.timeIntervalSince(last) / 3600.0
        // Guard against huge gaps (e.g. app was backgrounded) polluting the integral.
        guard hours < 0.02 else { return } // ignore gaps over ~1 minute
        let kWh = powerKW * hours
        if kWh >= 0 { energyUsedKWh += kWh } else { energyRegenKWh += -kWh }
    }
}
