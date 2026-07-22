import SwiftUI

private enum MapStage {
    case recordingBaseline
    case readyForAction
    case recordingActive
    case reviewCandidates
}

/// Same baseline → action → diff technique as Signal Detective, but for a CAN
/// ID that isn't in the reference sheet at all. Ends with you naming it
/// ("Driver door", "Window FL position", etc.) instead of matching it to an
/// existing sheet entry.
struct MapUnknownSignalView: View {
    let canID: UInt32
    @ObservedObject var obd: TeslaOBDManager
    @Environment(\.dismiss) private var dismiss

    /// When set (e.g. handed off from Action Scanner, which already recorded
    /// a baseline/action window), skip straight to candidate review instead
    /// of asking the user to record everything a second time.
    var prefilledAction: String? = nil
    var prefilledBaselineStart: Date? = nil
    var prefilledActiveStart: Date? = nil

    @State private var stage: MapStage = .recordingBaseline
    @State private var actionDescription = ""
    @State private var baselineStart: Date = Date()
    @State private var activeStart: Date?
    @State private var candidates: [BitCandidate] = []
    @State private var chosenIndex: Int?

    @State private var signalName = ""
    @State private var unit = ""
    @State private var scaleText = "1"
    @State private var offsetText = "0"

    init(canID: UInt32, obd: TeslaOBDManager,
         prefilledAction: String? = nil,
         prefilledBaselineStart: Date? = nil,
         prefilledActiveStart: Date? = nil) {
        self.canID = canID
        self.obd = obd
        self.prefilledAction = prefilledAction
        self.prefilledBaselineStart = prefilledBaselineStart
        self.prefilledActiveStart = prefilledActiveStart
        if let prefilledAction {
            _actionDescription = State(initialValue: prefilledAction)
        }
        if let prefilledBaselineStart {
            _baselineStart = State(initialValue: prefilledBaselineStart)
        }
        if let prefilledActiveStart {
            _activeStart = State(initialValue: prefilledActiveStart)
        }
        // If we already have a full baseline+action window from Action
        // Scanner, skip straight to running the analysis.
        if prefilledBaselineStart != nil, prefilledActiveStart != nil {
            _stage = State(initialValue: .reviewCandidates)
        }
    }

    var body: some View {
        Form {
            Section {
                Text("Mapping CAN ID 0x\(String(canID, radix: 16, uppercase: true))")
                    .font(.headline)
            }

            switch stage {
            case .recordingBaseline:
                Section("1. Baseline — leave things as they are for a few seconds") {
                    Text("Recording quiet traffic...")
                    ProgressView()
                    Button("Done recording baseline") { stage = .readyForAction }
                }

            case .readyForAction:
                Section("2. Describe and perform the action") {
                    TextField("e.g. \"Opened the driver door\"", text: $actionDescription)
                    Button("Start recording action") {
                        activeStart = Date()
                        stage = .recordingActive
                    }
                    .disabled(actionDescription.isEmpty)
                }

            case .recordingActive:
                Section("3. Recording — do the action now") {
                    Text(actionDescription)
                    ProgressView()
                    Button("Done — find candidates") { runAnalysis() }
                }

            case .reviewCandidates:
                Section("Candidates") {
                    if candidates.isEmpty {
                        Text("No bit window changed between baseline and action. Try again with a bigger or clearer action — or this ID may just be a heartbeat/counter unrelated to what you did.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { i, c in
                            Button {
                                chosenIndex = i
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("startBit \(c.startBit), \(c.bitLength)b, signed \(String(c.signed))")
                                            .font(.system(.caption, design: .monospaced))
                                        Text("baseline [\(fmt(c.baselineMin))–\(fmt(c.baselineMax))]  active [\(fmt(c.activeMin))–\(fmt(c.activeMax))]  score \(fmt(c.score))")
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if chosenIndex == i {
                                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                    }
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                if let chosenIndex, chosenIndex < candidates.count {
                    let c = candidates[chosenIndex]
                    Section("Name it") {
                        TextField("e.g. \"Driver door\"", text: $signalName)
                        TextField("Unit (optional, e.g. \"open/closed\", \"%\")", text: $unit)
                        Text("Raw active range [\(fmt(c.activeMin))–\(fmt(c.activeMax))] — set scale/offset if you want a physical unit, or leave scale=1 offset=0 to just see the raw number.")
                            .font(.caption2).foregroundColor(.secondary)
                        HStack { Text("Scale"); TextField("1", text: $scaleText).keyboardType(.decimalPad) }
                        HStack { Text("Offset"); TextField("0", text: $offsetText).keyboardType(.decimalPad) }
                        Button("Save") { save(candidate: c) }
                            .disabled(signalName.isEmpty)
                    }
                }

                Section {
                    Button("Start over") {
                        stage = .recordingBaseline
                        baselineStart = Date()
                        actionDescription = ""
                        candidates = []
                        chosenIndex = nil
                    }
                }
            }
        }
        .navigationTitle("Map signal")
        .onAppear {
            if prefilledBaselineStart != nil, prefilledActiveStart != nil, candidates.isEmpty {
                runAnalysis()
            }
        }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private func runAnalysis() {
        guard let activeStart else { return }
        let baselineFrames = obd.frameLog
            .filter { $0.canID == canID && $0.timestamp >= baselineStart && $0.timestamp < activeStart }
            .map { $0.bytes }
        let activeFrames = obd.frameLog
            .filter { $0.canID == canID && $0.timestamp >= activeStart }
            .map { $0.bytes }
        guard let dlc = (baselineFrames.first ?? activeFrames.first)?.count, dlc > 0 else {
            candidates = []
            stage = .reviewCandidates
            return
        }
        candidates = BitCandidateAnalyzer.candidates(baseline: baselineFrames, active: activeFrames, dlc: dlc)
        chosenIndex = nil
        stage = .reviewCandidates
    }

    private func save(candidate: BitCandidate) {
        guard let scale = Double(scaleText), let offset = Double(offsetText) else { return }
        let decode = CANDecode(
            startBit: candidate.startBit, bitLength: candidate.bitLength,
            signed: candidate.signed, scale: scale, offset: offset,
            note: "Self-mapped: \(actionDescription)"
        )
        let signal = CustomSignal(
            idHex: String(canID, radix: 16, uppercase: true),
            name: signalName, unit: unit, decode: decode, dateAdded: Date()
        )
        CustomSignalStore.shared.add(signal)
        dismiss()
    }
}
