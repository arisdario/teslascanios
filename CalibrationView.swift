import SwiftUI

private enum CalibrationStage {
    case pickSignal
    case recordingBaseline
    case readyForAction
    case recordingActive
    case reviewCandidates
    case error(String)
}

/// Manual signal calibration: record a quiet baseline, record a labeled action,
/// run the local bit-window diff analysis, then YOU pick the right candidate
/// and supply scale/offset — no external API involved, everything on-device.
struct CalibrationView: View {
    @ObservedObject var obd: TeslaOBDManager
    @ObservedObject private var userDecodes = UserDecodeStore.shared

    @State private var stage: CalibrationStage = .pickSignal
    @State private var selectedSignal: CANSignal?
    @State private var actionDescription = ""
    @State private var baselineStart: Date?
    @State private var activeStart: Date?
    @State private var candidates: [BitCandidate] = []

    @State private var chosenIndex: Int?
    @State private var scaleText: String = "1"
    @State private var offsetText: String = "0"

    private var undecodedSignals: [CANSignal] {
        TeslaSignalTable.shared.all.filter {
            $0.decode == nil && !$0.calculatedInApp && userDecodes.overrides["\($0.idHex)-\($0.name)"] == nil
        }
    }

    var body: some View {
        Form {
            switch stage {
            case .pickSignal:
                Section("1. Pick a signal to calibrate (\(undecodedSignals.count) remaining)") {
                    ForEach(undecodedSignals) { signal in
                        Button {
                            selectedSignal = signal
                            stage = .recordingBaseline
                            baselineStart = Date()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(signal.name)
                                Text("0x\(signal.idHex) · \(signal.numBits.map { "\($0) bits" } ?? "width unknown") · \(signal.unit)")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

            case .recordingBaseline:
                Section("2. Baseline — leave the car idle, don't touch anything") {
                    Text("Recording quiet traffic for \(selectedSignal?.name ?? "")...")
                    ProgressView()
                    Button("Done recording baseline (~5-10s is enough)") {
                        stage = .readyForAction
                    }
                }

            case .readyForAction:
                Section("3. Describe and perform the action") {
                    TextField("e.g. \"Pressed the brake pedal to about half\"", text: $actionDescription)
                    Button("Start recording action") {
                        activeStart = Date()
                        stage = .recordingActive
                    }
                    .disabled(actionDescription.isEmpty)
                }

            case .recordingActive:
                Section("4. Recording — do the action now") {
                    Text(actionDescription)
                    ProgressView()
                    Button("Done — find candidates") {
                        runAnalysis()
                    }
                }

            case .reviewCandidates:
                if let signal = selectedSignal {
                    Section("Candidates for \(signal.name)") {
                        if candidates.isEmpty {
                            Text("No bit window changed between baseline and action. Try a bigger/clearer action, or this signal may not live in this frame.")
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
                        Section("Scale / offset for \(signal.unit)") {
                            Text("Raw active range is [\(fmt(c.activeMin))–\(fmt(c.activeMax))]. Work out scale/offset so that range maps to a value that makes sense for \"\(signal.name)\" (\(signal.unit)) — e.g. if this is a 0-100% pedal and raw active range was ~0-250, scale ≈ 0.4.")
                                .font(.caption2).foregroundColor(.secondary)
                            HStack {
                                Text("Scale"); TextField("1", text: $scaleText).keyboardType(.decimalPad)
                            }
                            HStack {
                                Text("Offset"); TextField("0", text: $offsetText).keyboardType(.decimalPad)
                            }
                            Button("Save calibration") {
                                saveCalibration(signal: signal, candidate: c)
                            }
                        }
                    }

                    Section {
                        Button("Start over") { reset() }
                    }
                }

            case .error(let message):
                Section("Something went wrong") {
                    Text(message).foregroundColor(.red)
                    Button("Try again") { reset() }
                }
            }
        }
        .navigationTitle("Signal detective")
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private func runAnalysis() {
        guard let signal = selectedSignal, let canID = signal.canID,
              let baselineStart, let activeStart else { return }

        let baselineFrames = obd.frameLog
            .filter { $0.canID == canID && $0.timestamp >= baselineStart && $0.timestamp < activeStart }
            .map { $0.bytes }
        let activeFrames = obd.frameLog
            .filter { $0.canID == canID && $0.timestamp >= activeStart }
            .map { $0.bytes }

        guard let dlc = (baselineFrames.first ?? activeFrames.first)?.count, dlc > 0 else {
            stage = .error("No frames captured for CAN ID 0x\(signal.idHex) — check the adapter is connected and this ID is actually on the bus.")
            return
        }

        candidates = BitCandidateAnalyzer.candidates(baseline: baselineFrames, active: activeFrames, dlc: dlc)
        chosenIndex = nil
        stage = .reviewCandidates
    }

    private func saveCalibration(signal: CANSignal, candidate: BitCandidate) {
        guard let scale = Double(scaleText), let offset = Double(offsetText) else { return }
        let decode = CANDecode(
            startBit: candidate.startBit, bitLength: candidate.bitLength,
            signed: candidate.signed, scale: scale, offset: offset,
            note: "User-calibrated via Signal Detective (\(actionDescription))"
        )
        UserDecodeStore.shared.save(key: "\(signal.idHex)-\(signal.name)", decode: decode)
        reset()
    }

    private func reset() {
        selectedSignal = nil
        actionDescription = ""
        baselineStart = nil
        activeStart = nil
        candidates = []
        chosenIndex = nil
        scaleText = "1"
        offsetText = "0"
        stage = .pickSignal
    }
}
