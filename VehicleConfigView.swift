import SwiftUI

/// Shows the car's factory configuration/options — air suspension, HomeLink,
/// seat type, Autopilot hardware generation, etc. This is static per-vehicle
/// data (set once at the factory), not something that changes while driving,
/// so it lives on its own screen rather than in the live-values tabs.
struct VehicleConfigView: View {
    @EnvironmentObject private var obd: TeslaOBDManager

    private var configSignals: [CANSignal] {
        TeslaSignalTable.shared.all.filter { $0.isVehicleConfig }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Read from the car's gateway module — genuinely sourced from a leaked internal Tesla signal database, not fabricated, but unverified against a real capture. If a value looks wrong, it may just mean that option isn't applicable to your trim/year.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Section("Configuration (\(resolvedCount) of \(configSignals.count) read so far)") {
                    ForEach(configSignals.sorted(by: { $0.name < $1.name })) { signal in
                        HStack {
                            Text(signal.name)
                            Spacer()
                            if let label = resolvedLabel(for: signal) {
                                Text(label).foregroundColor(.secondary)
                            } else {
                                Text("no data yet").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Vehicle configuration")
        }
    }

    private var resolvedCount: Int {
        configSignals.filter { resolvedLabel(for: $0) != nil }.count
    }

    private func resolvedLabel(for signal: CANSignal) -> String? {
        guard let id = signal.canID, let bytes = obd.latestFrames[id], let decode = signal.decode else { return nil }
        if let label = decode.label(for: bytes) { return label }
        return decode.value(from: bytes).map { String(format: "%.0f", $0) }
    }
}
