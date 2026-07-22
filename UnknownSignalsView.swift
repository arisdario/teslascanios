import SwiftUI
import UIKit

/// Small clipboard helper used by the analyzer view.
private func copyToClipboard(_ text: String) {
    UIPasteboard.general.string = text
}

/// Lists every CAN ID currently seen on the bus that ISN'T in the reference
/// sheet — i.e. genuinely unmapped traffic. Lets you copy one or several as
/// plain text, formatted so you can paste it straight into a chat and ask
/// for help figuring out what it might be.
struct UnknownSignalsView: View {
    @EnvironmentObject private var obd: TeslaOBDManager
    @ObservedObject private var customSignals = CustomSignalStore.shared
    @State private var isSelecting = false
    @State private var selected = Set<UInt32>()

    private var knownIDs: Set<UInt32> {
        Set(TeslaSignalTable.shared.all.compactMap { $0.canID }).union(customSignals.mappedIDs)
    }

    private var unknownIDs: [UInt32] {
        obd.latestFrames.keys.filter { !knownIDs.contains($0) }.sorted()
    }

    /// Every distinct CAN ID seen this session, known or not — the number that
    /// actually answers "is this bus access broad or narrow," not just what's
    /// currently unmapped.
    private var allSeenIDs: [UInt32] {
        Set(obd.frameLog.map { $0.canID }).sorted()
    }

    var body: some View {
        NavigationView {
            List {
                Section("Session summary") {
                    HStack {
                        Text("Distinct CAN IDs seen")
                        Spacer()
                        Text("\(allSeenIDs.count)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Known / mapped")
                        Spacer()
                        Text("\(allSeenIDs.filter { knownIDs.contains($0) }.count)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Unmapped")
                        Spacer()
                        Text("\(unknownIDs.count)").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Total frames logged")
                        Spacer()
                        Text("\(obd.frameLog.count)").foregroundColor(.secondary)
                    }
                    Menu("Export") {
                        Button("Copy session summary") {
                            copyFullSummary() // your existing function, just renamed
                        }
                        Button("Copy full frame log (CSV)") {
                            copyFullFrameLog()
                        }
                    }
                }

                if !customSignals.signals.isEmpty {
                    Section("Mapped by you") {
                        let decoded = customSignals.decodeAll(from: obd.latestFrames)
                        ForEach(customSignals.signals) { signal in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(signal.name)
                                    Text("0x\(signal.idHex)").font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                if let value = decoded[signal.name] {
                                    Text("\(String(format: "%.2f", value.value)) \(value.unit)")
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("no data").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { customSignals.remove(signal) }
                            }
                        }
                    }
                }

                Section("Unmapped CAN IDs on the bus (\(unknownIDs.count))") {
                    if unknownIDs.isEmpty {
                        Text("No unmapped traffic seen yet — every ID observed so far is already in the reference sheet or mapped by you.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(unknownIDs, id: \.self) { id in
                            row(for: id)
                        }
                    }
                }
            }
            .navigationTitle("Unknown")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        if !isSelecting { selected.removeAll() }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    if isSelecting && !selected.isEmpty {
                        Button("Copy \(selected.count) selected") { copy(ids: Array(selected)) }
                    } else {
                        Button("Copy all unmapped") { copy(ids: unknownIDs) }
                            .disabled(unknownIDs.isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for id: UInt32) -> some View {
        if isSelecting {
            Button {
                if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            } label: {
                HStack {
                    rowContent(id: id)
                    Spacer()
                    Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selected.contains(id) ? .accentColor : .secondary)
                }
            }
            .foregroundColor(.primary)
        } else {
            NavigationLink {
                UnknownSignalDetailView(canID: id)
            } label: {
                rowContent(id: id)
            }
        }
    }

    private func rowContent(id: UInt32) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("0x\(String(id, radix: 16, uppercase: true))")
                .font(.system(.body, design: .monospaced))
            if let bytes = obd.latestFrames[id] {
                Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// Plain-text summary — one line per ID, its latest bytes. Good for a
    /// quick "what might these be" question covering several IDs at once.
    private func copy(ids: [UInt32]) {
        let text = ids.sorted().map { id -> String in
            let bytes = obd.latestFrames[id]?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "?"
            return "0x\(String(id, radix: 16, uppercase: true)): \(bytes)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    /// Exports everything at once: session stats, every known/decoded signal's
    /// current value, and every unmapped ID with its latest bytes — formatted
    /// to paste directly into a chat for debugging without extra back-and-forth.
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }
    
    private func copyFullFrameLog() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var lines = ["=== TeslaScan full frame log — \(Date()) ===",
                     "frames: \(obd.frameLog.count)",
                     "timestamp,canID,bytes"]
        
        for frame in obd.frameLog {
            let ts = formatter.string(from: frame.timestamp)
            let id = "0x\(String(frame.canID, radix: 16, uppercase: true))"
            let bytes = frame.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            lines.append("\(ts),\(id),\(bytes)")
        }
        
        copyToClipboard(lines.joined(separator: "\n"))
    }

    private func copyFullSummary() {
        var lines: [String] = []
        lines.append("=== TeslaScan session summary — copied \(timeFormatter.string(from: Date())) ===")
        lines.append("Distinct CAN IDs seen: \(allSeenIDs.count)")
        lines.append("Known/mapped: \(allSeenIDs.filter { knownIDs.contains($0) }.count)")
        lines.append("Unmapped: \(unknownIDs.count)")
        lines.append("Total frames logged: \(obd.frameLog.count)")
        lines.append("")

        lines.append("=== Known signal values ===")
        let decoded = TeslaSignalTable.shared.decodeAll(from: obd.latestFrames)
        if decoded.isEmpty {
            lines.append("(none decoded yet)")
        } else {
            for (name, entry) in decoded.sorted(by: { $0.key < $1.key }) {
                let valueText = entry.label ?? String(format: "%.3f", entry.value)
                lines.append("\(name): \(valueText) \(entry.unit)".trimmingCharacters(in: .whitespaces))
            }
        }
        lines.append("")

        lines.append("=== Unmapped CAN IDs (\(unknownIDs.count)) — latest bytes ===")
        if unknownIDs.isEmpty {
            lines.append("(none)")
        } else {
            for id in unknownIDs {
                let bytes = obd.latestFrames[id]?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "?"
                lines.append("0x\(String(id, radix: 16, uppercase: true)): \(bytes)")
            }
        }

        UIPasteboard.general.string = lines.joined(separator: "\n")
    }
}

/// Drill-in view for one unmapped CAN ID: shows the analyzer's findings —
/// per-byte activity, detected counters, and candidate field interpretations
/// with real observed ranges — plus recent raw samples and the Map action.
struct UnknownSignalDetailView: View {
    let canID: UInt32
    @EnvironmentObject private var obd: TeslaOBDManager

    private var payloads: [[UInt8]] {
        obd.frameLog.filter { $0.canID == canID }.map { $0.bytes }
    }

    private var analyzer: CANFrameAnalyzer {
        CANFrameAnalyzer(canID: canID, frames: payloads)
    }

    private var samples: [(timestamp: Date, bytes: [UInt8])] {
        obd.frameLog.filter { $0.canID == canID }.suffix(30).map { ($0.timestamp, $0.bytes) }
    }

    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }

    var body: some View {
        let stats = analyzer.byteStats()
        let counters = analyzer.counterByteIndices()
        let candidates = analyzer.candidates()

        return List {
            Section {
                NavigationLink {
                    MapUnknownSignalView(canID: canID, obd: obd)
                } label: {
                    Label("Map this signal (do an action, name what changes)", systemImage: "wand.and.stars")
                }
            }

            Section("Overview") {
                infoRow("Frames seen", "\(analyzer.frameCount)")
                infoRow("Payload length", "\(analyzer.dlc) bytes")
            }

            if !stats.isEmpty {
                Section("Byte activity") {
                    ForEach(0..<stats.count, id: \.self) { i in
                        HStack {
                            Text("Byte \(i)").font(.system(.caption, design: .monospaced))
                            Spacer()
                            if counters.contains(i) {
                                Text("counter").font(.caption).foregroundColor(.purple)
                            } else if stats[i].isStatic {
                                Text("static (\(String(format: "%02X", stats[i].min)))").font(.caption).foregroundColor(.secondary)
                            } else {
                                Text("min \(stats[i].min) max \(stats[i].max) · \(stats[i].changes) changes")
                                    .font(.caption).foregroundColor(.blue)
                            }
                        }
                    }
                }
            }

            if !candidates.isEmpty {
                Section("Candidate fields") {
                    Text("Every plausible multi-byte interpretation with its real observed range. Compare a range against what you'd expect (e.g. a temperature should sit in a sane °C band). Then use \"Map this signal\" to confirm which one tracks a real action.")
                        .font(.caption2).foregroundColor(.secondary)
                    ForEach(candidates) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.label).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text("[\(fmt(c.observedMin))–\(fmt(c.observedMax))]").font(.caption2).foregroundColor(.secondary)
                            }
                            Text(c.guess).font(.caption2).foregroundColor(guessColor(c.guess))

                            // Correlate this candidate against known signals.
                            let matches = SignalCorrelator.correlate(
                                unknownID: canID, startBit: c.startBit, bitLength: c.bitLength,
                                endian: c.endian, frameLog: obd.frameLog)
                            if let top = matches.first {
                                Text("↳ tracks \(top.knownSignalName) (r=\(String(format: "%.2f", top.correlation)), n=\(top.sampleCount))")
                                    .font(.caption2).foregroundColor(.green)
                            }
                        }
                    }
                }
            }

            Section("Recent samples (\(samples.count))") {
                ForEach(Array(samples.enumerated().reversed()), id: \.offset) { _, sample in
                    HStack {
                        Text(formatter.string(from: sample.timestamp))
                            .font(.caption2).foregroundColor(.secondary)
                        Text(sample.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
            }
        }
        .navigationTitle("0x\(String(canID, radix: 16, uppercase: true))")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Copy") { copyAnalysis(stats: stats, counters: counters, candidates: candidates) }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.0f", v) }

    private func guessColor(_ guess: String) -> Color {
        if guess.contains("counter") { return .purple }
        if guess.contains("Analog") || guess.contains("sensor") { return .green }
        if guess.contains("Static") { return .secondary }
        return .blue
    }

    private func copyAnalysis(stats: [ByteStat], counters: Set<Int>, candidates: [FieldCandidate]) {
        var lines = ["CAN ID 0x\(String(canID, radix: 16, uppercase: true)) — \(analyzer.frameCount) frames, \(analyzer.dlc) bytes"]
        lines.append("Byte activity:")
        for (i, s) in stats.enumerated() {
            if counters.contains(i) { lines.append("  Byte \(i): ROLLING COUNTER") }
            else if s.isStatic { lines.append("  Byte \(i): static \(String(format: "%02X", s.min))") }
            else { lines.append("  Byte \(i): min \(s.min) max \(s.max), \(s.changes) changes") }
        }
        lines.append("Candidate fields:")
        for c in candidates {
            lines.append("  \(c.label): [\(fmt(c.observedMin))–\(fmt(c.observedMax))] — \(c.guess)")
        }
        copyToClipboard(lines.joined(separator: "\n"))
    }
}
