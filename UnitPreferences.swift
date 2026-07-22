import Foundation
import Combine

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius = "C"
    case fahrenheit = "F"
    var id: String { rawValue }
    var label: String { self == .celsius ? "Celsius" : "Fahrenheit" }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case km = "km"
    case miles = "mi"
    var id: String { rawValue }
    var label: String { self == .km ? "Kilometers" : "Miles" }
}

/// User's preferred display units. Persisted so the choice survives relaunch.
final class UnitPreferences: ObservableObject {
    @Published var temperature: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperature.rawValue, forKey: "temperatureUnit") }
    }
    @Published var distance: DistanceUnit {
        didSet { UserDefaults.standard.set(distance.rawValue, forKey: "distanceUnit") }
    }

    init() {
        temperature = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "") ?? .celsius
        distance = DistanceUnit(rawValue: UserDefaults.standard.string(forKey: "distanceUnit") ?? "") ?? .km
    }
}

/// Converts a decoded (value, unit) pair to the user's preferred display units.
/// Signals whose native unit isn't temperature/distance/speed pass through unchanged.
enum UnitConverter {
    static func display(value: Double, unit: String, prefs: UnitPreferences) -> (value: Double, unit: String) {
        switch unit {
        case "C":
            return prefs.temperature == .fahrenheit ? (value * 9 / 5 + 32, "F") : (value, "C")
        case "km":
            return prefs.distance == .miles ? (value / 1.60934, "mi") : (value, "km")
        case "mi":
            return prefs.distance == .km ? (value * 1.60934, "km") : (value, "mi")
        case "km/h", "km|h":
            return prefs.distance == .miles ? (value / 1.60934, "mph") : (value, "km/h")
        case "mph":
            return prefs.distance == .km ? (value * 1.60934, "km/h") : (value, "mph")
        default:
            return (value, unit)
        }
    }
}
