import SwiftUI

struct BatteryModulesView: View {
    @EnvironmentObject private var obd: TeslaOBDManager

    private var snapshot: ValidatedCellTelemetry {
        obd.validatedBatteryData
    }

    private let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )
    
    

    var body: some View {
        
        
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    
                    warningCard
                    
                    if snapshot.cellVoltages.isEmpty {
                        waitingCard
                    }

                    summaryCard
                    voltageCard
                    temperatureCard
                    decoderStatusCard
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Battery cell groups")
            .background(Color(.systemGroupedBackground))
        }
    }

    private var warningCard: some View {
        card {
            Text(
                "Experimental classic-pack decoder for CAN ID 0x6F2. " +
                "Cell groups and temperature channels appear progressively " +
                "as their selector frames are received."
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var waitingCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Waiting for battery telemetry")
                    .font(.headline)

                Text(
                    "Waiting for the first valid CAN 0x6F2 frame. " +
                    "Values will populate progressively as selector frames arrive."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var summaryCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle(
                    "\(snapshot.isValidated ? "Complete" : "Live partial") telemetry " +
                    "(\(snapshot.cellVoltages.count)/96 cells, " +
                    "\(snapshot.moduleTemps.count)/32 temperatures)"
                )

                statRow(
                    "Cell average",
                    snapshot.averageVoltage,
                    unit: "V",
                    decimals: 3
                )

                Divider()

                statRow(
                    "Cell minimum",
                    snapshot.minimumVoltage,
                    unit: "V",
                    decimals: 3
                )

                Divider()

                statRow(
                    "Cell maximum",
                    snapshot.maximumVoltage,
                    unit: "V",
                    decimals: 3
                )

                Divider()

                statRow(
                    "Cell difference",
                    snapshot.deltaVoltage,
                    unit: "V",
                    decimals: 3
                )

                Divider()

                statRow(
                    "Temperature average",
                    snapshot.averageTemperature,
                    unit: "°C",
                    decimals: 1
                )

                Divider()

                statRow(
                    "Temperature minimum",
                    snapshot.minimumTemperature,
                    unit: "°C",
                    decimals: 1
                )

                Divider()

                statRow(
                    "Temperature maximum",
                    snapshot.maximumTemperature,
                    unit: "°C",
                    decimals: 1
                )
            }
        }
    }

    private var voltageCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Cell-group voltages (1–96)")

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(1...96, id: \.self) { cell in
                        cellTile(
                            number: cell,
                            value: snapshot.cellVoltages[cell],
                            unit: "V",
                            decimals: 3
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var temperatureCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Temperature channels (1–32)")

                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(1...32, id: \.self) { channel in
                        cellTile(
                            number: channel,
                            value: snapshot.moduleTemps[channel],
                            unit: "°C",
                            decimals: 1
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var decoderStatusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Decoder status")

                Text(
                    "The decoder expects 32 selectors: 24 voltage frames for " +
                    "96 cell groups and 8 temperature frames for 32 channels. " +
                    "Values appear as each valid selector arrives."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                HStack {
                    Text("Cycle status")
                    Spacer()

                    Text(snapshot.isValidated ? "Complete" : "Collecting")
                        .foregroundStyle(
                            snapshot.isValidated ? .green : .orange
                        )
                }
                .font(.caption)

                if let receivedAt = snapshot.receivedAt {
                    Divider()

                    HStack {
                        Text(
                            snapshot.isValidated
                                ? "Last complete update"
                                : "Last frame received"
                        )

                        Spacer()

                        Text(receivedAt.formatted())
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(
        _ label: String,
        _ value: Double?,
        unit: String,
        decimals: Int
    ) -> some View {
        HStack {
            Text(label)
            Spacer()

            if let value {
                Text(
                    "\(String(format: "%.\(decimals)f", value)) \(unit)"
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cellTile(
        number: Int,
        value: Double?,
        unit: String,
        decimals: Int
    ) -> some View {
        VStack(spacing: 3) {
            Text("#\(number)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let value {
                Text(String(format: "%.\(decimals)f", value))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
