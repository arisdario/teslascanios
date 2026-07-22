import SwiftUI

/// Connection settings: shows the remembered adapter (auto-reconnected on
/// launch), lets you pick a different one, or forget it. This is the "moved to
/// Settings" home for device selection — the app connects to the saved device
/// automatically on open, so you normally never need to come here after setup.
struct ConnectionSettingsView: View {
    @ObservedObject var obd: TeslaOBDManager
    @State private var showPicker = false
    @AppStorage("savedDeviceName") private var savedName: String = ""

    var body: some View {
        List {
            Section("Adapter") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(obd.statusText).foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if !savedName.isEmpty {
                    HStack {
                        Text("Saved device")
                        Spacer()
                        Text(savedName).foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Button(savedName.isEmpty ? "Choose adapter" : "Choose a different adapter") {
                    showPicker = true
                }
                .disabled(obd.isConnected && savedName.isEmpty)

                if !savedName.isEmpty {
                    Button("Forget saved device", role: .destructive) {
                        obd.forgetSavedDevice()
                        savedName = ""
                    }
                }
            } footer: {
                Text(savedName.isEmpty
                     ? "Pick your OBD adapter once. The app will remember it and reconnect automatically each time you open it."
                     : "The app auto-connects to this device on launch. Choose a different one only if you switch adapters.")
            }
        }
        .navigationTitle("Connection")
        .sheet(isPresented: $showPicker) {
            DevicePickerView(obd: obd)
        }
    }
}
