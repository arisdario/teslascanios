import SwiftUI
import Combine

/// User-set values the dashboard math needs but the car doesn't broadcast in a
/// decodable form: original pack capacity (for degradation) and an efficiency
/// assumption (for the range model). Persisted.
final class DashboardSettings: ObservableObject {
    @Published var originalPackKWh: Double {
        didSet { UserDefaults.standard.set(originalPackKWh, forKey: "originalPackKWh") }
    }
    @Published var whPerMile: Double {
        didSet { UserDefaults.standard.set(whPerMile, forKey: "whPerMile") }
    }
    init() {
        let savedPack = UserDefaults.standard.double(forKey: "originalPackKWh")
        originalPackKWh = savedPack > 0 ? savedPack : 85.0   // sensible default for a Model S
        let savedWh = UserDefaults.standard.double(forKey: "whPerMile")
        whPerMile = savedWh > 0 ? savedWh : 300.0
    }
}

struct DashboardView: View {
    @EnvironmentObject private var obd: TeslaOBDManager
    @EnvironmentObject private var units: UnitPreferences
    @StateObject private var settings = DashboardSettings()
    @StateObject private var trip = TripTracker()

    private var decoded: [String: (value: Double, unit: String, note: String?, label: String?)] {
        TeslaSignalTable.shared.decodeAll(from: obd.latestFrames)
    }

    var body: some View {
        NavigationView {
            List {
                // Big, glanceable "what's happening right now" tiles — the
                // point is you shouldn't have to read small list rows to see
                // current power draw while driving.
                Section {
                    consumptionTiles
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Power") {
                    metricRow("Battery power", Dashboard.batteryPowerKW(decoded), "kW")
                    metricRow("Drive power", Dashboard.drivePowerKW(decoded), "kW")
                    metricRow("Regen power", Dashboard.regenPowerKW(decoded), "kW")
                }

                Section("Energy & range") {
                    metricRow("Usable remaining", Dashboard.usableRemainingKWh(decoded), "kWh")
                    rangeRow()
                    efficiencyRow()
                }

                Section("Battery health") {
                    degradationRow()
                    HStack {
                        Text("Original pack size")
                        Spacer()
                        TextField("85", value: $settings.originalPackKWh, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                        Text("kWh").foregroundColor(.secondary)
                    }
                    Text("Set your car's original capacity (60/70/85/90/100). Degradation compares the car's current nominal full-pack energy against this.")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Section("Trip") {
                    if trip.isActive {
                        metricRow("Energy used", trip.energyUsedKWh, "kWh")
                        metricRow("Energy regenerated", trip.energyRegenKWh, "kWh")
                        metricRow("Net energy", trip.energyUsedKWh - trip.energyRegenKWh, "kWh")
                        Button("Stop trip") { trip.stop() }
                    } else {
                        Button("Start trip") { trip.start() }
                        if trip.energyUsedKWh > 0 || trip.energyRegenKWh > 0 {
                            metricRow("Last trip used", trip.energyUsedKWh, "kWh")
                            metricRow("Last trip regen", trip.energyRegenKWh, "kWh")
                        }
                    }
                }

                Section("Efficiency assumption") {
                    HStack {
                        Text(units.distance == .km ? "Wh per kilometer" : "Wh per mile")
                        Spacer()
                        TextField(
                            units.distance == .km ? "186" : "300",
                            value: Binding(
                                get: {
                                    units.distance == .km
                                        ? settings.whPerMile / 1.609344
                                        : settings.whPerMile
                                },
                                set: { displayedValue in
                                    settings.whPerMile = units.distance == .km
                                        ? displayedValue * 1.609344
                                        : displayedValue
                                }
                            ),
                            format: .number
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    }
                    Text("Used for the range estimate below. TeslaScan stores one canonical value internally and converts the setting for metric or imperial display.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Dashboard")
            .onReceive(obd.$latestFrames) { _ in
                trip.accumulate(powerKW: Dashboard.batteryPowerKW(decoded))
            }
        }
    }

    private func metricRow(_ label: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let value {
                Text("\(String(format: "%.2f", value)) \(unit)").foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
    }

    /// Three large tiles: net power, drive draw, regen recovery. Color-coded
    /// so you can read them at a glance while driving instead of scanning a
    /// list. Shows "—" rather than 0 when there's no data yet.
    private var consumptionTiles: some View {
        HStack(spacing: 10) {
            powerTile(
                title: "Power",
                value: Dashboard.batteryPowerKW(decoded),
                color: (Dashboard.batteryPowerKW(decoded) ?? 0) >= 0 ? .orange : .green
            )
            powerTile(
                title: "Drive",
                value: Dashboard.drivePowerKW(decoded),
                color: .orange
            )
            powerTile(
                title: "Regen",
                value: Dashboard.regenPowerKW(decoded),
                color: .green
            )
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func powerTile(title: String, value: Double?, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundColor(.secondary)
            if let value {
                Text(String(format: "%.1f", abs(value)))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                    .monospacedDigit()
                Text("kW")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Text("kW").font(.caption2).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(value == nil ? 0.05 : 0.12))
        .cornerRadius(12)
    }

    private func rangeRow() -> some View {
        let miles = Dashboard.estimatedRangeMiles(decoded, whPerMile: settings.whPerMile)
        return HStack {
            Text("Estimated range")
            Spacer()
            if let miles {
                let (val, unit) = units.distance == .km ? (miles * 1.60934, "km") : (miles, "mi")
                Text("~\(String(format: "%.0f", val)) \(unit)").foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
    }

    private func efficiencyRow() -> some View {
        let wpm = Dashboard.instantEfficiencyWhPerMile(decoded)
        return HStack {
            Text("Efficiency (instant)")
            Spacer()
            if let wpm {
                let (val, unit) = units.distance == .km ? (wpm / 1.60934, "Wh/km") : (wpm, "Wh/mi")
                Text("\(String(format: "%.0f", val)) \(unit)").foregroundColor(.secondary)
            } else {
                Text("— (moving only)").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func degradationRow() -> some View {
        let deg = Dashboard.degradationPercent(decoded, originalKWh: settings.originalPackKWh)
        return HStack {
            Text("Degradation")
            Spacer()
            if let deg {
                Text("\(String(format: "%.1f", deg))%").foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
    }
}
