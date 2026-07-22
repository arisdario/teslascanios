import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @StateObject private var obd = TeslaOBDManager()
    @StateObject private var units = UnitPreferences()

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dash", systemImage: "gauge.with.dots.needle.bottom.50percent") }

            CategoryTabView(category: .battery, icon: "battery.100")
                .tabItem { Label("Battery", systemImage: "battery.100") }

            CategoryTabView(category: .drivetrain, icon: "gauge.with.needle")
                .tabItem { Label("Drivetrain", systemImage: "gauge.with.needle") }

            SignalsHubView()
                .tabItem { Label("Signals", systemImage: "list.bullet.rectangle") }

            MoreView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .environmentObject(obd)
        .environmentObject(units)
    }
}

/// Hub tab consolidating the less-frequently-used signal views so the top-level
/// tab bar stays at 5 (iOS hides anything beyond that in a system overflow).
struct SignalsHubView: View {
    @EnvironmentObject private var obd: TeslaOBDManager

    var body: some View {
        NavigationView {
            List {
                Section("Live signal categories") {
                    NavigationLink { CategoryTabView(category: .hvac, icon: "wind") } label: {
                        Label("HVAC", systemImage: "wind")
                    }
                    NavigationLink { CategoryTabView(category: .vehicle, icon: "car") } label: {
                        Label("Vehicle", systemImage: "car")
                    }
                    NavigationLink { CategoryTabView(category: .other, icon: "square.grid.2x2") } label: {
                        Label("Other", systemImage: "square.grid.2x2")
                    }
                }
                Section("Discovery & battery detail") {
                    NavigationLink { ActionScannerView() } label: {
                        Label("Action Scanner (find door/window/light IDs)", systemImage: "sparkle.magnifyingglass")
                    }
                    NavigationLink { UnknownSignalsView() } label: {
                        Label("Unknown / unmapped IDs", systemImage: "questionmark.circle")
                    }
                    NavigationLink { BatteryModulesView() } label: {
                        Label("Battery cell groups", systemImage: "square.grid.3x3")
                    }
                }
            }
            .navigationTitle("Signals")
        }
    }
}

/// One tab per SignalCategory. Battery gets an extra "Battery modules" section
/// for experimental classic-pack cell-group and temperature telemetry
/// carried by CAN ID 0x6F2.
struct CategoryTabView: View {
    let category: SignalCategory
    let icon: String

    @EnvironmentObject private var obd: TeslaOBDManager
    @EnvironmentObject private var units: UnitPreferences

    private var signalsInCategory: [CANSignal] {
        TeslaSignalTable.shared.all.filter { $0.category == category && !$0.isBatteryModule && !$0.isVehicleConfig }
    }
    private var moduleSignals: [CANSignal] {
        TeslaSignalTable.shared.all.filter { $0.isBatteryModule }
    }

    var body: some View {
        NavigationView {
            List {
                ConnectionStatusSection(obd: obd)

                let decoded = TeslaSignalTable.shared.decodeAll(from: obd.latestFrames)
                let namesInCategory = Set(signalsInCategory.map { $0.name })
                let relevant = decoded.filter { namesInCategory.contains($0.key) }

                Section("\(category.rawValue) (\(signalsInCategory.filter { $0.decode != nil }.count) decodable of \(signalsInCategory.count))") {
                    if relevant.isEmpty {
                        Text("Waiting for data...").foregroundColor(.secondary)
                    } else {
                        ForEach(relevant.sorted(by: { $0.key < $1.key }), id: \.key) { name, entry in
                            SignalRow(name: name, entry: entry, units: units)
                        }
                    }
                    if category == .battery, let power = TeslaDerived.batteryPowerKW(from: obd.latestFrames) {
                        HStack {
                            Text("Battery power (derived)")
                            Spacer()
                            Text("\(String(format: "%.2f", power)) kW").foregroundColor(.secondary)
                        }
                    }
                }

                if category == .battery {
                    Section("Battery modules") {
                        NavigationLink("Open validated cell-group view") {
                            BatteryModulesView()
                        }
                    }
                }

                if category == .vehicle {
                    Section("Vehicle configuration") {
                        NavigationLink("Open factory options/hardware config (45 fields)") {
                            VehicleConfigView()
                        }
                    }
                }
            }
            .navigationTitle(category.rawValue)
        }
    }
}

private struct SignalRow: View {
    let name: String
    let entry: (value: Double, unit: String, note: String?, label: String?)
    let units: UnitPreferences

    var body: some View {
        let converted = UnitConverter.display(value: entry.value, unit: entry.unit, prefs: units)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name)
                Spacer()
                if let label = entry.label {
                    Text(label).foregroundColor(.secondary)
                } else {
                    Text("\(String(format: "%.2f", converted.value)) \(converted.unit)")
                        .foregroundColor(.secondary)
                }
            }
            if let note = entry.note {
                Text(note).font(.caption2).foregroundColor(.orange)
            }
        }
    }
}

private struct ConnectionStatusSection: View {
    @ObservedObject var obd: TeslaOBDManager
    @State private var showPicker = false

    var body: some View {
        Section("Connection") {
            Text(obd.statusText)
            Button("Rescan") { showPicker = true }
                .disabled(obd.isConnected)
            if !obd.discoveredCharacteristics.isEmpty {
                NavigationLink("BLE characteristics found (\(obd.discoveredCharacteristics.count))") {
                    CharacteristicsDebugView(obd: obd)
                }
            }
            NavigationLink("Raw console (\(obd.rawResponseLog.count) responses)") {
                RawDebugConsoleView(obd: obd)
            }
        }
        .sheet(isPresented: $showPicker) {
            DevicePickerView(obd: obd)
        }
    }
}

/// Shows every service/characteristic UUID and property set the connected
/// adapter actually exposes — useful if auto-selection picked the wrong
/// write/notify pair, or found nothing, and you need to see the real layout.
private struct CharacteristicsDebugView: View {
    @ObservedObject var obd: TeslaOBDManager

    var body: some View {
        List(obd.discoveredCharacteristics) { char in
            VStack(alignment: .leading, spacing: 2) {
                Text(char.charUUID.uuidString).font(.system(.body, design: .monospaced))
                Text("service \(char.serviceUUID.uuidString)").font(.caption2).foregroundColor(.secondary)
                Text(char.properties).font(.caption).foregroundColor(.blue)
            }
        }
        .navigationTitle("BLE characteristics")
    }
}

/// Settings, units, the full reference browser, raw-frame debug view, and the
/// Signal Detective all live here rather than cluttering the category tabs.
struct MoreView: View {
    @EnvironmentObject private var obd: TeslaOBDManager
    @EnvironmentObject private var units: UnitPreferences

    var body: some View {
        NavigationView {
            List {
                Section("Connection") {
                    NavigationLink {
                        ConnectionSettingsView(obd: obd)
                    } label: {
                        Label("Adapter & auto-connect", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section("Units") {
                    Picker("System", selection: Binding(
                        get: {
                            if units.distance == .miles && units.temperature == .fahrenheit { return "Imperial" }
                            if units.distance == .km && units.temperature == .celsius { return "Metric" }
                            return "Custom"
                        },
                        set: { newValue in
                            if newValue == "Imperial" {
                                units.distance = .miles
                                units.temperature = .fahrenheit
                            } else if newValue == "Metric" {
                                units.distance = .km
                                units.temperature = .celsius
                            }
                        }
                    )) {
                        Text("Metric (km, °C)").tag("Metric")
                        Text("Imperial (mi, °F)").tag("Imperial")
                    }
                    .pickerStyle(.segmented)

                    Picker("Temperature", selection: $units.temperature) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    Picker("Distance / speed", selection: $units.distance) {
                        ForEach(DistanceUnit.allCases) { unit in
                            Text(unit.label).tag(unit)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {

                        Divider()

                        Text("Diagnostics")
                            .font(.headline)

                        HStack {

                            Button("Read DTCs") {
                                obd.readDTCs()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!obd.isConnected || obd.isReadingDTCs)

                            Button("Clear DTCs") {
                                obd.clearDTCs()
                            }
                            .buttonStyle(.bordered)
                            .disabled(true)        // Keep disabled until we've verified Mode 03
                        }

                        if let status = obd.dtcStatusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !obd.dtcCodes.isEmpty {

                            Text("Codes")
                                .font(.caption)
                                .bold()

                            ForEach(obd.dtcCodes, id: \.self) { code in
                                Text(code)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }

                        if !obd.dtcRawResponse.isEmpty {

                            Text("Raw Response")
                                .font(.caption)
                                .bold()

                            ForEach(obd.dtcRawResponse, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                

                Section {
                    NavigationLink("Browse all \(TeslaSignalTable.shared.all.count) known signals") { SignalReferenceView() }
                    NavigationLink("Signal detective (manual calibration)") { CalibrationView(obd: obd) }
                }
            }
            .navigationTitle("More")
        }
    }
}

/// Reference browser for the full "Scan My Tesla" sheet — useful while you're
/// still calibrating startBit/scale for signals that only have numBits so far.
struct SignalReferenceView: View {
    var body: some View {
        List(TeslaSignalTable.shared.all) { signal in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(signal.name).bold()
                    Spacer()
                    Text("0x\(signal.idHex)").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                }
                HStack {
                    Text(signal.category.rawValue).font(.caption).foregroundColor(.blue)
                    if let bits = signal.numBits {
                        Text("\(bits) bits").font(.caption).foregroundColor(.secondary)
                    }
                    if !signal.unit.isEmpty {
                        Text(signal.unit).font(.caption).foregroundColor(.secondary)
                    }
                    if signal.decode != nil {
                        Text("✓ decodable").font(.caption).foregroundColor(.green)
                    } else if signal.calculatedInApp {
                        Text("derived, not raw").font(.caption).foregroundColor(.blue)
                    } else {
                        Text("needs bit calibration").font(.caption).foregroundColor(.orange)
                    }
                }
                if !signal.comment.isEmpty {
                    Text(signal.comment).font(.caption2).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("All signals")
    }
}

#Preview {
    ContentView()
}
