import SwiftUI

/// Shows every raw text chunk the adapter sends back and lets you send
/// arbitrary AT commands by hand — the fastest way to figure out what an
/// adapter actually does without a laptop/Xcode console attached.
struct RawDebugConsoleView: View {
    @ObservedObject var obd: TeslaOBDManager

    @State private var customCommand = ""
    @State private var filterID = ""

    var body: some View {
        VStack(spacing: 0) {
            responseList

            Divider()

            controls
                .padding()
        }
        .navigationTitle("Raw console")
    }

    private var responseList: some View {
        List {
            if obd.rawResponseLog.isEmpty {
                Text(
                    "No responses received yet. If you just connected, tap a command below to test — even ATZ alone tells you whether anything comes back at all."
                )
                .foregroundColor(.secondary)
            } else {
                ForEach(
                    Array(obd.rawResponseLog.enumerated().reversed()),
                    id: \.offset
                ) { _, entry in
                    Text(entry)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Capture")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Toggle("Log changes only", isOn: $obd.logChangesOnly)
                    .font(.caption)
                    .fixedSize()
            }

            HStack {
                TextField("Filter ID range, e.g. 100", text: $filterID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)

                Button("Watch range") {
                    watchEnteredRange()
                }

                Button("All") {
                    obd.stopRotating()
                    obd.monitorAll()
                }
            }

            Button(
                obd.isRotating
                    ? "Stop rotating capture"
                    : "Rotate all blocks (capture everything over time)"
            ) {
                if obd.isRotating {
                    obd.stopRotating()
                } else {
                    obd.startRotatingFilter()
                }
            }
            .font(.caption)

            HStack {
                TextField("Custom AT command, e.g. ATZ", text: $customCommand)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onSubmit {
                        sendCustomCommand()
                    }

                Button("Send") {
                    sendCustomCommand()
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(
                        ["ATZ", "ATE0", "ATI", "ATSP6", "ATMA", "ATDPN"],
                        id: \.self
                    ) { command in
                        Button(command) {
                            obd.stopRotating()
                            obd.send(command)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func watchEnteredRange() {
        let cleaned = filterID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "0x",
                with: "",
                options: [.caseInsensitive, .anchored]
            )

        guard let filter = UInt32(cleaned, radix: 16), filter <= 0x7FF else {
            return
        }

        obd.stopRotating()
        obd.monitorRange(filter: filter, mask: 0x700)
        filterID = String(format: "%03X", filter)
    }

    private func sendCustomCommand() {
        let command = customCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard !command.isEmpty else {
            return
        }

        obd.stopRotating()
        obd.send(command)
        customCommand = ""
    }
}
