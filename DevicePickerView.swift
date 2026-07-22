import SwiftUI
import CoreBluetooth
#if canImport(UIKit)
import UIKit
#endif

/// Shown when the user taps Rescan — lists every nearby BLE device (not just
/// ones matching a name guess) so they can pick their adapter directly, the
/// same way any BLE app works. There's no "pair in Settings" step for BLE
/// devices like the iCar Pro; this in-app picker is the actual connection flow.
struct DevicePickerView: View {
    @ObservedObject var obd: TeslaOBDManager
    @Environment(\.dismiss) private var dismiss

    private var sortedDevices: [TeslaOBDManager.DiscoveredPeripheral] {
        obd.discoveredPeripherals.sorted { $0.rssi > $1.rssi } // closer/stronger signal first
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    switch obd.bluetoothState {
                    case .poweredOn:
                        HStack {
                            if obd.isScanning {
                                ProgressView().padding(.trailing, 4)
                                Text("Scanning for nearby devices...")
                            } else {
                                Text("Scan stopped")
                                Spacer()
                                Button("Scan again") { obd.startScan() }
                            }
                        }
                    case .poweredOff:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bluetooth is off on this iPhone.")
                            Text("Turn it on in Control Center or Settings, then reopen this screen.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    case .unauthorized:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This app doesn't have Bluetooth permission.")
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    case .unsupported:
                        Text("This device has no Bluetooth LE support (e.g. the Simulator). Use a real iPhone.")
                            .foregroundColor(.secondary)
                    case .resetting:
                        HStack { ProgressView(); Text("Bluetooth is resetting, one moment...") }
                    case .unknown:
                        HStack { ProgressView(); Text("Checking Bluetooth status...") }
                    }
                }

                Section("Nearby devices (\(sortedDevices.count))") {
                    if sortedDevices.isEmpty {
                        Text(obd.isScanning ? "Looking..." : "No devices found. Make sure the adapter is plugged in and powered.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sortedDevices) { device in
                            Button {
                                obd.connect(to: device)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text(device.peripheral.identifier.uuidString)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text("\(device.rssi) dBm")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }

                Section {
                    Text("Look for a name containing something like \"OBD\", \"iCar\", \"Vgate\", or a string of letters/numbers if the adapter doesn't advertise a friendly name. Signal strength (dBm, closer to 0 = stronger) can help you tell devices apart if several show up.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Choose your adapter")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        obd.stopScan()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if !obd.isScanning { obd.startScan() }
        }
    }
}
