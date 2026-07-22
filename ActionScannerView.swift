import SwiftUI

/// Finds which CAN ID(s) respond to a physical action, across the WHOLE bus at
/// once — the tool for discovering where doors/windows/lights live without
/// knowing the ID in advance. Workflow: record a baseline (car untouched), then
/// perform one action (open a door), then it ranks every ID by how much its
/// bytes changed. The top hit is almost always the signal you're looking for.
struct ActionScannerView: View {
    @EnvironmentObject private var obd: TeslaOBDManager

    enum Stage { case idle, baseline, action, results }
    @State private var stage: Stage = .idle
    @State private var actionName = ""
    @State private var baselineStart = Date()
    @State private var actionStart = Date()
    @State private var results: [IDChange] = []

    struct IDChange: Identifiable {
        var id: UInt32 { canID }
        let canID: UInt32
        let changedByteCount: Int
        let changedBytes: [Int]        // which byte positions moved
        let baselineSample: [UInt8]
        let actionSample: [UInt8]
    }

    var body: some View {
        List {
            Section {
                Text("Find which CAN ID a physical action controls. Record a baseline while the car is untouched, perform ONE action (e.g. open the driver door), then see which IDs changed. Best done with a filtered range that includes body IDs (try Watch range 0x100 or 0x300 first).")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Action") {
                TextField("What are you testing? e.g. driver door", text: $actionName)
                    .autocorrectionDisabled()
            }

            switch stage {
            case .idle:
                Button("1. Start baseline (don't touch anything)") {
                    baselineStart = Date()
                    stage = .baseline
                }
                .disabled(actionName.isEmpty)

            case .baseline:
                Section {
                    HStack { ProgressView(); Text("Recording baseline — keep the car untouched...") }
                    Button("2. Baseline done — now DO the action") {
                        actionStart = Date()
                        stage = .action
                    }
                }

            case .action:
                Section {
                    HStack { ProgressView(); Text("Now perform: \(actionName)") }
                    Button("3. Done — show what changed") {
                        runScan()
                        stage = .results
                    }
                }

            case .results:
                Section("IDs that changed for: \(actionName)") {
                    if results.isEmpty {
                        Text("No ID changed between baseline and action. Either the signal is outside the current filter range (try a different Watch range), the action was too subtle, or the change is too fast to catch. Try again with a bigger/clearer action.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(results) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("0x\(String(r.canID, radix: 16, uppercase: true))")
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("\(r.changedByteCount) byte\(r.changedByteCount == 1 ? "" : "s") changed")
                                        .font(.caption).foregroundColor(.blue)
                                }
                                Text("bytes \(r.changedBytes.map(String.init).joined(separator: ", "))")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("before: \(hex(r.baselineSample))").font(.caption2).foregroundColor(.secondary)
                                Text("after:  \(hex(r.actionSample))").font(.caption2).foregroundColor(.green)

                                // The missing link: jump straight into the same
                                // baseline→action naming flow Map Unknown Signal
                                // uses, already knowing which ID to look at.
                                NavigationLink {
                                    MapUnknownSignalView(
                                        canID: r.canID, obd: obd,
                                        prefilledAction: actionName,
                                        prefilledBaselineStart: baselineStart,
                                        prefilledActiveStart: actionStart
                                    )
                                } label: {
                                    Label("Map this as \"\(actionName)\"", systemImage: "tag")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .padding(.top, 2)
                            }
                        }
                    }
                    Button("Scan another action") {
                        results = []
                        actionName = ""
                        stage = .idle
                    }
                }
            }
        }
        .navigationTitle("Action Scanner")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Compares the last baseline frame vs the last action frame for every ID,
    /// and reports those whose bytes differ — ranked by how many bytes changed
    /// (fewer changed bytes = cleaner, more specific signal, so we sort ascending
    /// among the changed set but surface all of them).
    private func runScan() {
        var baselineByID: [UInt32: [UInt8]] = [:]
        var actionByID: [UInt32: [UInt8]] = [:]

        for f in obd.frameLog where f.timestamp >= baselineStart && f.timestamp < actionStart {
            baselineByID[f.canID] = f.bytes
        }
        for f in obd.frameLog where f.timestamp >= actionStart {
            actionByID[f.canID] = f.bytes
        }

        var changes: [IDChange] = []
        for (id, actionBytes) in actionByID {
            guard let baseBytes = baselineByID[id], baseBytes.count == actionBytes.count else { continue }
            var changedPositions: [Int] = []
            for i in 0..<actionBytes.count where baseBytes[i] != actionBytes[i] {
                changedPositions.append(i)
            }
            if !changedPositions.isEmpty {
                changes.append(IDChange(canID: id, changedByteCount: changedPositions.count,
                                        changedBytes: changedPositions,
                                        baselineSample: baseBytes, actionSample: actionBytes))
            }
        }
        // Sort: fewest changed bytes first (most specific/cleanest hits on top),
        // since a door-open flag typically flips just one or two bytes, while a
        // counter-heavy frame changes many.
        results = changes.sorted { $0.changedByteCount < $1.changedByteCount }
    }
}
