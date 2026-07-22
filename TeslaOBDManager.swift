import Foundation
import CoreBluetooth
import Combine

/// Talks to a BLE ELM327-compatible adapter (iCar Pro) and streams raw CAN frames.
///
/// IMPORTANT: Fill in `serviceUUID` / `writeCharUUID` / `notifyCharUUID` after
/// discovering them once with a generic BLE inspector app (e.g. "LightBlue").
/// Vgate/iCar-style clones commonly expose a UART-like service, but the exact
/// UUIDs vary by firmware batch, so don't hardcode a guess.
final class TeslaOBDManager: NSObject, ObservableObject {

    // MARK: - Fill these in after discovery
    static let serviceUUID    = CBUUID(string: "FFF0") // placeholder — verify
    static let writeCharUUID  = CBUUID(string: "FFF2") // placeholder — verify
    static let notifyCharUUID = CBUUID(string: "FFF1") // placeholder — verify

    /// One nearby BLE device found while scanning. Shown in a picker instead
    /// of guessing which one is the adapter by name — BLE devices like the
    /// iCar Pro don't pair through iOS Settings at all, they're discovered
    /// and connected to directly by the app.
    struct DiscoveredPeripheral: Identifiable, Equatable {
        let id: UUID
        let peripheral: CBPeripheral
        let name: String
        let rssi: Int

        static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool { lhs.id == rhs.id }
    }

    /// Mirrors CBManagerState but as something the UI can switch on directly,
    /// so screens can show the real reason instead of a generic "stopped".
    enum BluetoothState {
        case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
    }

    /// Every characteristic found during discovery, regardless of whether it
    /// got auto-selected as write/notify — shown in a debug view so if
    /// auto-selection picks wrong (or finds nothing), you can see the real
    /// UUIDs/properties this specific adapter exposes.
    struct DiscoveredCharacteristic: Identifiable {
        let id = UUID()
        let serviceUUID: CBUUID
        let charUUID: CBUUID
        let properties: String
    }

    // MARK: - Published state
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var statusText = "Not connected"
    @Published var bluetoothState: BluetoothState = .unknown
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var discoveredCharacteristics: [DiscoveredCharacteristic] = []
    /// Latest decoded CAN frames, keyed by CAN ID. PUBLISHED = drives the UI,
    /// but updated only on a throttled timer (see flushTimer), NOT on every
    /// frame — otherwise a busy bus triggers hundreds of SwiftUI redraws per
    /// second, saturates the main thread, and the BLE callback can't drain the
    /// buffer fast enough → "buffer full".
    @Published var latestFrames: [UInt32: [UInt8]] = [:]
    
    @Published private(set) var debug6F2Frames: [[UInt8]] = []

    private let debug6F2FrameLimit = 500
    
    @Published private(set) var validatedBatteryData =
        ValidatedCellTelemetry()

    /// Rolling timestamped history, needed for the calibration/detective feature.
    @Published var frameLog: [(timestamp: Date, canID: UInt32, bytes: [UInt8])] = []
    private let frameLogCap = 400000

    // Fast-path internal storage: written on every frame (cheap, no UI cost),
    // then mirrored to the @Published properties above a few times per second.
    // We keep only NEW frames since the last flush (a batch) and append them,
    // rather than re-copying the whole 40k-frame log each flush.
    private var pendingFrames: [UInt32: [UInt8]] = [:]
    private var pendingFrameBatch: [(timestamp: Date, canID: UInt32, bytes: [UInt8])] = []
    private var pendingRawLogBatch: [String] = []
    private var flushTimer: Timer?
    private var uiDirty = false
    
    private let classicBMSDecoder = BMS6F2Decoder()

    private let configuredCellTelemetryFormat: CellTelemetryFormat =
        .classicSXMux6F2

    private var lastObservedPackVoltage: Double?
    private var lastPackVoltageTimestamp: Date?
    private let maximumPackVoltageAge: TimeInterval = 60

    // Watchdog state for auto-recovery from BUFFER FULL / stalls.
    private var lastValidFrameTime = Date()
    private var bufferFullCount = 0
    private var recoveryInProgress = false
    private var watchdogTimer: Timer?
    private var activeFilter: UInt32 = 0x000
    private var activeMask: UInt32 = 0x700

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var pendingServiceCount = 0

    /// Buffers partial responses until we see the ELM327 '>' prompt.
    private var rxBuffer = ""

    /// When true, the historical frameLog only records a frame when its payload
    /// differs from the previous one for that ID — big storage/clarity win on a
    /// bus full of unchanging cyclic frames. Live values still update every frame.
    @Published var logChangesOnly = true
    private var lastLoggedPayload: [UInt32: [UInt8]] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.flushToUI()
        }
        // Watchdog: if frames stop arriving while we think we're monitoring, or
        // BUFFER FULL shows up repeatedly, automatically re-issue the monitor
        // command instead of silently going dead until the user reconnects.
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkMonitorHealth()
        }
    }

    deinit {
        flushTimer?.invalidate()
        watchdogTimer?.invalidate()
    }

    /// Appends the batch of frames received since the last flush to the published
    /// properties, and trims to cap. Appending a small batch is far cheaper than
    /// re-copying the entire 40k-frame log on every flush.
    private func flushToUI() {
        guard uiDirty else { return }
        uiDirty = false

        latestFrames = pendingFrames

        if !pendingFrameBatch.isEmpty {
            frameLog.append(contentsOf: pendingFrameBatch)
            pendingFrameBatch.removeAll(keepingCapacity: true)
            if frameLog.count > frameLogCap {
                frameLog.removeFirst(frameLog.count - frameLogCap)
            }
        }

        if !pendingRawLogBatch.isEmpty {
            rawResponseLog.append(contentsOf: pendingRawLogBatch)
            pendingRawLogBatch.removeAll(keepingCapacity: true)
            if rawResponseLog.count > rawLogCap {
                rawResponseLog.removeFirst(rawResponseLog.count - rawLogCap)
            }
        }
    }

    // MARK: - Monitor health watchdog

    private func checkMonitorHealth() {
        guard isConnected, isMonitoring, !recoveryInProgress else { return }
        let stalledFor = Date().timeIntervalSince(lastValidFrameTime)
        if stalledFor > 2.5 || bufferFullCount >= 2 {
            recoverMonitor()
        }
    }

    /// Re-establish monitor mode after a stall/overflow, reusing whatever filter
    /// was active, without needing the user to disconnect and reconnect.
    private func recoverMonitor() {
        guard !recoveryInProgress else { return }
        recoveryInProgress = true
        bufferFullCount = 0

        commandQueue.removeAll()
        isWaitingForResponse = false
        isMonitoring = false

        send("")     // interrupt any half-running monitor
        send("ATPC") // cleanly close the protocol/exit monitor before restarting
        send("ATCF\(String(format: "%03X", activeFilter & 0x7FF))")
        send("ATCM\(String(format: "%03X", activeMask & 0x7FF))")
        send("ATMA")

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.recoveryInProgress = false
            self?.lastValidFrameTime = Date()
        }
    }

    /// Starts (or restarts) a scan. This is what should trigger the iOS "Allow
    /// Bluetooth" permission prompt the first time it's called — if that prompt
    /// never appears, check Info.plist has NSBluetoothAlwaysUsageDescription set.
    func startScan() {
        guard central.state == .poweredOn else {
            statusText = "Bluetooth not powered on"
            return
        }
        discoveredPeripherals = []
        isScanning = true
        statusText = "Scanning..."
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if statusText == "Scanning..." { statusText = "Scan stopped" }
    }

    /// Call this once the user taps a device in the picker.
    func connect(to discovered: DiscoveredPeripheral) {
        stopScan()
        writeChar = nil
        notifyChar = nil
        discoveredCharacteristics = []
        pendingServiceCount = 0
        peripheral = discovered.peripheral
        discovered.peripheral.delegate = self
        statusText = "Connecting to \(discovered.name)..."
        central.connect(discovered.peripheral, options: nil)

        // Remember this device so we can auto-reconnect on next launch.
        UserDefaults.standard.set(discovered.id.uuidString, forKey: "savedDeviceUUID")
        UserDefaults.standard.set(discovered.name, forKey: "savedDeviceName")
    }

    /// The remembered device's name, if any — for showing in Settings.
    var savedDeviceName: String? {
        UserDefaults.standard.string(forKey: "savedDeviceName")
    }

    /// Forget the saved device so the app stops auto-connecting to it.
    func forgetSavedDevice() {
        UserDefaults.standard.removeObject(forKey: "savedDeviceUUID")
        UserDefaults.standard.removeObject(forKey: "savedDeviceName")
    }

    /// Attempt to reconnect to the previously-selected device without a full
    /// scan, using CoreBluetooth's retrievePeripherals(withIdentifiers:). Called
    /// automatically once Bluetooth is powered on. No-op if nothing was saved.
    func attemptAutoReconnect() {
        guard central.state == .poweredOn, !isConnected,
              let uuidString = UserDefaults.standard.string(forKey: "savedDeviceUUID"),
              let uuid = UUID(uuidString: uuidString) else { return }

        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let target = known.first {
            writeChar = nil
            notifyChar = nil
            discoveredCharacteristics = []
            pendingServiceCount = 0
            peripheral = target
            target.delegate = self
            statusText = "Reconnecting to \(savedDeviceName ?? "saved adapter")..."
            central.connect(target, options: nil)
        } else {
            // The peripheral isn't cached (e.g. it was off) — fall back to a
            // brief scan and auto-connect when it appears.
            autoReconnectScanning = true
            startScan()
            // Don't scan forever if the adapter never shows up (e.g. unplugged).
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.autoReconnectScanning, !self.isConnected else { return }
                self.autoReconnectScanning = false
                self.stopScan()
                self.statusText = "Saved adapter not found — open Connection settings to pick one."
            }
        }
    }

    /// True while we're scanning specifically to find the saved device to
    /// auto-connect, so didDiscover knows to connect on sight rather than just
    /// listing it.
    private var autoReconnectScanning = false

    // MARK: - Sending commands

    /// Raw text the adapter sends back, one entry per received chunk — lets
    /// you see exactly what's happening (or not) at the AT-command level,
    /// independent of whether CAN frame parsing succeeds.
    @Published var rawResponseLog: [String] = []
    private let rawLogCap = 100

    private var commandQueue: [String] = []
    private var isWaitingForResponse = false
    private var isMonitoring = false
    /// Increments each time a command is actually sent — lets a scheduled
    /// timeout confirm it still belongs to the command currently in flight
    /// before acting, so a stale timeout from an earlier command can't
    /// misfire and cut off a later command's response window.
    private var currentCommandToken = 0

    /// Queues a raw AT / ELM command instead of writing it immediately — commands
    /// are sent one at a time, only once the previous command's response (the
    /// ELM327 '>' prompt) has been seen. Firing them all back-to-back caused
    /// commands to be dropped while the chip was still processing ATZ's reset.
    func send(_ command: String) {
        commandQueue.append(command)
        processQueueIfIdle()
    }

    // MARK: - Diagnostic Trouble Codes (Mode 03 / 04)
    //
    // Standard OBD-II services: Mode 03 reads stored DTCs, Mode 04 clears
    // them. HONEST CAVEAT: Tesla's onboard gateway is not required to
    // implement these — they're emissions-diagnostic services from the ICE
    // world, and an EV has no emissions system to report faults on. Some
    // Teslas expose a subset for state-inspection compatibility, some don't.
    // "NO DATA" or no response at all is inconclusive, not proof the car has
    // no stored faults — it may just mean this service isn't implemented.
    // Raw response text is always shown alongside any parsed codes so you can
    // see exactly what came back rather than trusting the parser blindly.

    @Published var dtcCodes: [String] = []
    @Published var dtcRawResponse: [String] = []
    @Published var dtcStatusMessage: String?
    @Published var isReadingDTCs = false

    private var awaitingDTCResponse = false
    private var dtcResponseLines: [String] = []
    private var wasMonitoringBeforeDTC = false
    private var dtcModeWasClear = false

    func readDTCs() {
        guard isConnected, !isReadingDTCs else { return }
        beginDTCExchange(clear: false)
        send("03")
    }

    func clearDTCs() {
        guard isConnected, !isReadingDTCs else { return }
        beginDTCExchange(clear: true)
        send("04")
    }

    private func beginDTCExchange(clear: Bool) {
        isReadingDTCs = true
        dtcModeWasClear = clear
        dtcStatusMessage = nil
        dtcCodes = []
        dtcRawResponse = []
        wasMonitoringBeforeDTC = isMonitoring
        awaitingDTCResponse = true
        dtcResponseLines = []
        // Mode 03/04 needs the bus to itself — can't run alongside raw monitor
        // mode. Stop monitoring, do the exchange, then resume where we left off.
        stopMonitoring()
    }

    /// Called for each raw line while a DTC exchange is in flight, instead of
    /// the normal CAN-frame parser (mode 03/04 responses aren't CAN monitor
    /// frames and would otherwise get silently dropped or misread).
    private func handleDTCLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ">" else { return }
        dtcResponseLines.append(trimmed)
    }

    /// Runs once the '>' prompt confirms the DTC response is complete.
    private func finalizeDTCExchange() {
        dtcRawResponse = dtcResponseLines

        let joined = dtcResponseLines.joined(separator: " ").uppercased()
        if joined.contains("NO DATA") {
            dtcStatusMessage = dtcModeWasClear
                ? "No response to clear request — service may not be supported."
                : "No response — either no stored codes, or this service isn't implemented on this vehicle."
        } else if dtcModeWasClear {
            if joined.contains("44") || joined.contains("OK") {
                dtcStatusMessage = "Clear request acknowledged."
            } else {
                dtcStatusMessage = "Unclear response to clear request — see raw text below."
            }
        } else {
            dtcCodes = Self.parseDTCResponse(dtcResponseLines)
            dtcStatusMessage = dtcCodes.isEmpty
                ? "No codes parsed. This may mean zero stored codes, or that the response format wasn't recognized — check the raw text below."
                : "\(dtcCodes.count) code(s) found."
        }

        isReadingDTCs = false
        awaitingDTCResponse = false
        if wasMonitoringBeforeDTC {
            monitorRange(filter: activeFilter, mask: activeMask)
        }
    }

    /// Parses Mode 03 response lines into standard 5-character DTC strings
    /// (e.g. "P0301"). Handles the common single-frame case; does not handle
    /// multi-frame ISO-TP responses with many codes — if you have more DTCs
    /// than fit in one frame, the raw text will show more than gets parsed.
    private static func parseDTCResponse(_ lines: [String]) -> [String] {
        var codes: [String] = []
        for line in lines {
            let hexOnly = line.filter { $0.isHexDigit }
            guard hexOnly.count >= 2 else { continue }
            var bytes: [UInt8] = []
            var idx = hexOnly.startIndex
            while idx < hexOnly.endIndex {
                let next = hexOnly.index(idx, offsetBy: 2, limitedBy: hexOnly.endIndex) ?? hexOnly.endIndex
                if let b = UInt8(hexOnly[idx..<next], radix: 16) { bytes.append(b) }
                idx = next
            }
            // Find the "43" mode-response byte, then read DTC pairs after it.
            guard let modeIdx = bytes.firstIndex(of: 0x43) else { continue }
            var i = modeIdx + 1
            while i + 1 < bytes.count {
                let a = bytes[i], b = bytes[i + 1]
                i += 2
                if a == 0, b == 0 { continue } // padding
                let categoryChars = ["P", "C", "B", "U"]
                let category = categoryChars[Int((a >> 6) & 0x3)]
                let digit1 = (a >> 4) & 0x3
                let digit2 = a & 0xF
                let digit3 = (b >> 4) & 0xF
                let digit4 = b & 0xF
                let code = String(format: "%@%X%X%X%X", category, digit1, digit2, digit3, digit4)
                codes.append(code)
            }
        }
        return codes
    }
    
    private func decodeTeslaTelemetry(
        canID: UInt32,
        payload: [UInt8],
        timestamp: Date
    ) {
        switch canID {
        case 0x102:
            decodePackVoltage(
                payload: payload,
                timestamp: timestamp
            )

        case BMS6F2Decoder.canID:
            guard configuredCellTelemetryFormat == .classicSXMux6F2 else {
                return
            }

            let referencePackVoltage: Double?

            if let voltageTimestamp = lastPackVoltageTimestamp,
               timestamp.timeIntervalSince(voltageTimestamp) <= maximumPackVoltageAge {
                referencePackVoltage = lastObservedPackVoltage
            } else {
                referencePackVoltage = nil
            }

            if let snapshot = classicBMSDecoder.processFrame(
                payload: payload,
                totalPackVoltage: referencePackVoltage,
                timestamp: timestamp
            ) {
                validatedBatteryData = snapshot
            }

        default:
            break
        }
    }

    private func decodePackVoltage(
        payload: [UInt8],
        timestamp: Date
    ) {
        guard payload.count >= 2 else {
            return
        }

        // wk057: byte 0 is low byte, byte 1 is high byte,
        // with a scale of 0.01 volts per bit.
        let rawVoltage =
            UInt16(payload[0]) |
            (UInt16(payload[1]) << 8)

        let voltage = Double(rawVoltage) * 0.01

        guard 200.0...500.0 ~= voltage else {
            return
        }

        lastObservedPackVoltage = voltage
        lastPackVoltageTimestamp = timestamp
    }

    private func processQueueIfIdle() {
        guard !commandQueue.isEmpty, let peripheral, let writeChar else { return }
        if isMonitoring {
            // A new command implicitly interrupts ATMA's streaming mode —
            // otherwise isWaitingForResponse would stay true forever and every
            // command after ATMA would sit stuck in the queue, never sent.
            isMonitoring = false
            isWaitingForResponse = false
        }
        guard !isWaitingForResponse else { return }

        let command = commandQueue.removeFirst()
        isWaitingForResponse = true
        currentCommandToken += 1
        let myToken = currentCommandToken

        let payload = (command + "\r").data(using: .ascii)!
        let type: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(payload, for: writeChar, type: type)
        pendingRawLogBatch.append("→ \(command)")
        uiDirty = true

        let upper = command.uppercased()
        if upper == "ATMA" {
            // Monitor mode streams continuously and never sends a completion
            // prompt — leave isWaitingForResponse set (see isMonitoring above)
            // rather than scheduling a timeout that would falsely imply this
            // command "finished."
            isMonitoring = true
            return
        }
        let extraDelay: TimeInterval = upper == "ATZ" ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + extraDelay) { [weak self] in
            guard let self, self.isWaitingForResponse, self.currentCommandToken == myToken else { return }
            self.isWaitingForResponse = false
            self.processQueueIfIdle()
        }
    }

    /// Standard ELM327 init sequence + switch into raw CAN monitor mode.
    /// ATSP6 = ISO 15765-4 CAN, 11-bit ID, 500 kbps (Tesla's diagnostic-accessible bus).
    /// ATMA  = monitor all traffic (since we want ~100 different IDs, not one PID).
    func runSetupSequence() {
        stopRotating()

        // Queue the complete initialization and the first monitor block in one
        // uninterrupted sequence. Calling monitorRange() here would invoke
        // stopMonitoring(), which clears commandQueue and can discard setup
        // commands before the adapter receives them.
        let setup = [
            "ATZ",    // reset
            "ATE0",   // echo off
            "ATL0",   // linefeeds off
            "ATS0",   // spaces off
            "ATH1",   // headers ON — we need the CAN ID
            "ATCAF0", // CAN auto-formatting off — raw CAN frames
            "ATSP6",  // ISO 15765-4 CAN, 11-bit ID, 500 kbps
            "ATCF000",
            "ATCM700",
            "ATMA"
        ]

        activeFilter = 0x000
        activeMask = 0x700
        rotateIndex = 0

        for cmd in setup {
            send(cmd)
        }

        // Begin rotation only after the serialized setup sequence and initial
        // monitor session have had time to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self, self.isConnected else { return }
            self.beginRotationTimer(secondsPerBlock: 4)
        }
    }

    /// Monitor only CAN IDs matching a filter+mask, instead of the whole bus.
    /// This is the reliable way to pull detailed data from ELM327-class hardware:
    /// the adapter only relays matching frames, so BLE throughput stops being the
    /// bottleneck and those frames come through clean instead of mangled.
    ///
    /// ATCF sets the filter (which bits to match), ATCM sets the mask (which bits
    /// matter). Example: filter 0x100, mask 0x700 → matches 0x100–0x1FF.
    /// Pass a single ID with mask 0x7FF to watch exactly one message.
    func monitorRange(filter: UInt32, mask: UInt32) {
        activeFilter = filter
        activeMask = mask
        stopMonitoring()
        // Re-issue the minimal setup in case a prior ATZ reset cleared it.
        send("ATCF\(String(format: "%03X", filter & 0x7FF))")
        send("ATCM\(String(format: "%03X", mask & 0x7FF))")
        send("ATMA")
    }

    /// Watch exactly one CAN ID — the cleanest possible capture for reverse
    /// engineering a specific message (e.g. while doing a known action).
    func monitorSingleID(_ id: UInt32) {
        monitorRange(filter: id, mask: 0x7FF)
    }

    /// Clear any filter and go back to watching the whole bus.
    func monitorAll() {
        activeFilter = 0x000
        activeMask = 0x000
        stopRotating()
        stopMonitoring()
        send("ATCM000") // mask 000 = match everything
        send("ATMA")
    }

    // MARK: - Rotating filter (capture all blocks over time without overload)

    private var rotateTimer: Timer?
    private let rotateBlocks: [UInt32] = [
        0x100,
        0x200,
        0x100,
        0x300,
        0x100,
        0x400,
        0x100,
        0x500,
        0x100,
        0x600,
        0x100,
        0x700,
        0x100,
        0x000
    ]
    private var rotateIndex = 0
    @Published var isRotating = false

    /// Cycles the monitor filter through each 0x100-block every few seconds. This
    /// captures signals across the whole bus over time while only ever watching
    /// one block at a time — the reliable way to get broad coverage on an
    /// ELM327-class adapter that can't handle the full firehose.
    func startRotatingFilter(secondsPerBlock: TimeInterval = 1.5) {
        stopRotating()
        rotateIndex = 0
        monitorRange(filter: rotateBlocks[0], mask: 0x700)

        // Give the first filter command sequence a short time to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.isConnected else { return }
            self.beginRotationTimer(secondsPerBlock: secondsPerBlock)
        }
    }

    private func beginRotationTimer(secondsPerBlock: TimeInterval) {
        rotateTimer?.invalidate()

        rotateTimer = Timer.scheduledTimer(
            withTimeInterval: secondsPerBlock,
            repeats: true
        ) { [weak self] _ in
            guard let self, self.isConnected else { return }

            self.rotateIndex =
                (self.rotateIndex + 1) % self.rotateBlocks.count

            self.monitorRange(
                filter: self.rotateBlocks[self.rotateIndex],
                mask: 0x700
            )
        }
    }

    func stopRotating() {
        rotateTimer?.invalidate()
        rotateTimer = nil
        isRotating = false
    }

    func stopMonitoring() {
        // Any character interrupts ATMA on ELM327-compatible chips.
        commandQueue.removeAll()
        isWaitingForResponse = false
        isMonitoring = false
        send("")
    }

    // MARK: - Parsing raw monitor-mode output

    /// A single line like "102 8 1234A0FF00000000" (ID, DLC, hex payload) —
    /// exact spacing/format depends on your adapter's firmware; adjust the
    /// regex below once you've captured a live sample.
    private func parseLine(_ line: String) {
        // Strip whitespace AND any stray characters that aren't hex — some
        // adapters intersperse the '>' prompt or CR/LF mid-stream.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ">" else { return }

        // Two possible monitor-mode formats depending on whether spaces are on:
        //   spaced   (ATS1):  "102 34 56 78 9A BC DE F0"  → ID then byte pairs
        //   unspaced (ATS0):  "10234567 89ABCDEF"  or  "102123456789ABCDEF"
        // We ran ATS0 in setup, so handle the unspaced case as the primary path
        // and fall back to the spaced parse if spaces are present.

        var idHex: String
        var payloadHex: String

        if trimmed.contains(" ") {
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { return }

            idHex = String(parts[0])

            let remaining = parts.dropFirst().map(String.init)

            // Some ELM327 firmwares emit:
            //   ID DLC BYTE BYTE ...
            // while others emit:
            //   ID BYTE BYTE ...
            // Treat the first field as DLC only when its value exactly matches
            // the number of following byte fields.
            if let declaredLength = Int(remaining[0], radix: 16),
               declaredLength <= 8,
               remaining.count == declaredLength + 1 {
                payloadHex = remaining.dropFirst().joined()
            } else {
                payloadHex = remaining.joined()
            }
        } else {
            // No spaces: the ID is the first 3 hex chars (11-bit CAN ID),
            // everything after is the payload. Strip any trailing '>' too.
            let clean = trimmed.replacingOccurrences(of: ">", with: "")
            guard clean.count > 3 else { return }

            let idxAfterID = clean.index(clean.startIndex, offsetBy: 3)
            idHex = String(clean[clean.startIndex..<idxAfterID])

            var remainder = String(clean[idxAfterID...])

            // Some ELM327 firmwares insert a one-nibble DLC immediately after
            // the three-character CAN ID, for example:
            //   1028AABBCCDDEEFF0011
            // Remove it only when its value exactly matches the following byte count.
            if let first = remainder.first,
               let declaredLength = Int(String(first), radix: 16),
               declaredLength <= 8 {
                let candidate = String(remainder.dropFirst())
                if candidate.count == declaredLength * 2 {
                    remainder = candidate
                }
            }

            payloadHex = remainder
        }

        // Reject misaligned garbage: a valid frame has an even-length payload
        // (whole bytes) of at most 8 bytes (16 hex chars). When frames get
        // concatenated or split mid-byte, the payload comes out odd-length or
        // way too long — dropping those prevents the fake low-ID / stray-byte
        // artifacts (e.g. "0xA3: ...22 AE") from polluting the data.
        guard payloadHex.count % 2 == 0, payloadHex.count <= 16, !payloadHex.isEmpty else { return }
        // Every character must be a valid hex digit — a stray non-hex char means
        // this line is mis-split, not a real frame.
        guard payloadHex.allSatisfy({ $0.isHexDigit }), idHex.allSatisfy({ $0.isHexDigit }) else { return }

        guard let canID = UInt32(idHex, radix: 16) else { return }

        var bytes: [UInt8] = []
        var idx = payloadHex.startIndex
        while idx < payloadHex.endIndex {
            let next = payloadHex.index(idx, offsetBy: 2, limitedBy: payloadHex.endIndex) ?? payloadHex.endIndex
            if let byte = UInt8(payloadHex[idx..<next], radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        guard !bytes.isEmpty else { return }

        // A valid frame arrived — reset the watchdog stall/overflow tracking.
        lastValidFrameTime = Date()
        bufferFullCount = 0

        // Fast path: write to internal storage only (no @Published = no UI redraw).
        let frameTimestamp = Date()
        decodeTeslaTelemetry(
            canID: canID,
            payload: bytes,
            timestamp: frameTimestamp
        )
        
        pendingFrames[canID] = bytes
        uiDirty = true

        if logChangesOnly {
            if lastLoggedPayload[canID] == bytes { return }
            lastLoggedPayload[canID] = bytes
        }

        // Append only to the pending batch; trimming happens in flushToUI.
        pendingFrameBatch.append((frameTimestamp, canID, bytes))
    }
}

// MARK: - CBCentralManagerDelegate

extension TeslaOBDManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = .poweredOn
            // If we have a remembered device, try to reconnect to it directly
            // rather than opening a scan; only scan if nothing is saved.
            if UserDefaults.standard.string(forKey: "savedDeviceUUID") != nil {
                attemptAutoReconnect()
            } else {
                startScan()
            }
        case .poweredOff:
            bluetoothState = .poweredOff
            statusText = "Bluetooth is off — turn it on in Settings or Control Center"
        case .unauthorized:
            bluetoothState = .unauthorized
            statusText = "Bluetooth permission denied — enable in Settings > Privacy > Bluetooth"
        case .unsupported:
            bluetoothState = .unsupported
            statusText = "This device/simulator has no BLE support — use a real iPhone, not the Simulator"
        case .resetting:
            bluetoothState = .resetting
            statusText = "Bluetooth is resetting, try again in a moment"
        case .unknown:
            bluetoothState = .unknown
            statusText = "Bluetooth state unknown, waiting..."
        @unknown default:
            bluetoothState = .unknown
            statusText = "Bluetooth unavailable (unrecognized state)"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unnamed device"
        let entry = DiscoveredPeripheral(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue)

        if let idx = discoveredPeripherals.firstIndex(where: { $0.id == entry.id }) {
            discoveredPeripherals[idx] = entry // refresh RSSI on repeat sightings
        } else {
            discoveredPeripherals.append(entry)
        }

        // If we're scanning to auto-reconnect and this is the saved device,
        // connect to it immediately.
        if autoReconnectScanning,
           let savedUUID = UserDefaults.standard.string(forKey: "savedDeviceUUID"),
           entry.id.uuidString == savedUUID {
            autoReconnectScanning = false
            connect(to: entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        statusText = "Connected — discovering services"
        peripheral.discoverServices(nil) // nil = ask for everything, don't guess a UUID
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        statusText = "Disconnected"
    }
}

// MARK: - CBPeripheralDelegate

extension TeslaOBDManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            statusText = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            statusText = "Connected, but this device exposes no BLE services at all — likely not a compatible adapter"
            return
        }
        pendingServiceCount = services.count
        statusText = "Found \(services.count) service(s) — checking characteristics..."
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service) // nil = ask for everything here too
        }
    }

    /// True for a full 128-bit vendor UUID (e.g. "BEF8D6C9-9C21-...") vs a
    /// short Bluetooth SIG-standard one (e.g. "2AF0"). Vendors' actual
    /// proprietary data channel is virtually always a full custom UUID — SIG
    /// short UUIDs are shared/standardized services (Device Information,
    /// Battery Service, etc.) and are never the real ELM327 pipe, even though
    /// some happen to expose write+notify properties that look plausible.
    private func isCustomUUID(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.count > 4
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            pendingServiceCount -= 1
            finalizeCharacteristicSelectionIfReady(peripheral)
            return
        }

        for char in chars {
            let props = describeProperties(char.properties)
            discoveredCharacteristics.append(
                DiscoveredCharacteristic(serviceUUID: service.uuid, charUUID: char.uuid, properties: props)
            )

            let candidateIsCustom = isCustomUUID(char.uuid)

            if char.uuid == Self.writeCharUUID {
                writeChar = char // exact match to a manually-pinned UUID always wins
            } else if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                let currentIsCustom = writeChar.map { isCustomUUID($0.uuid) } ?? false
                if writeChar == nil || (candidateIsCustom && !currentIsCustom) {
                    writeChar = char
                }
            }

            if char.uuid == Self.notifyCharUUID {
                notifyChar = char
            } else if char.properties.contains(.notify) || char.properties.contains(.indicate) {
                let currentIsCustom = notifyChar.map { isCustomUUID($0.uuid) } ?? false
                if notifyChar == nil || (candidateIsCustom && !currentIsCustom) {
                    notifyChar = char
                }
            }
        }

        pendingServiceCount -= 1
        finalizeCharacteristicSelectionIfReady(peripheral)
    }

    /// Only commits to a write/notify pair and starts the ELM327 setup sequence
    /// once every service's characteristics have been checked — otherwise a
    /// plausible-but-wrong match found early (like a standard SIG service)
    /// locks in before a better custom-UUID candidate is even discovered.
    private func finalizeCharacteristicSelectionIfReady(_ peripheral: CBPeripheral) {
        guard pendingServiceCount <= 0 else {
            statusText = "Checking remaining services (\(pendingServiceCount) left)... found \(discoveredCharacteristics.count) characteristics so far"
            return
        }
        guard let writeChar, let notifyChar else {
            statusText = "No writable+notifiable characteristic pair found — checked all services, \(discoveredCharacteristics.count) characteristics total. See the characteristics list for what this adapter actually exposes."
            return
        }
        peripheral.setNotifyValue(true, for: notifyChar)
        isConnected = true
        statusText = "Ready (write: \(writeChar.uuid.uuidString.prefix(8))…, notify: \(notifyChar.uuid.uuidString.prefix(8))…)"
        runSetupSequence()
    }

    private func describeProperties(_ props: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if props.contains(.read) { parts.append("read") }
        if props.contains(.write) { parts.append("write") }
        if props.contains(.writeWithoutResponse) { parts.append("writeNoResponse") }
        if props.contains(.notify) { parts.append("notify") }
        if props.contains(.indicate) { parts.append("indicate") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyChar?.uuid, let data = characteristic.value else { return }

        // Log unconditionally, in both hex and best-effort text — ASCII decoding
        // can silently return nil and drop the whole chunk if the adapter sends
        // even one non-ASCII byte, which would otherwise look identical to
        // "nothing came back at all." Latin-1 never fails (all 256 byte values
        // map 1:1), so it's used for the actual parsing buffer too.
        // Skip the expensive per-byte hex formatting on the hot path — just keep
        // the decoded text. (A hex view could be added behind a debug toggle.)
        let text = String(data: data, encoding: .isoLatin1) ?? ""

        // Detect the adapter reporting overflow so the watchdog can auto-recover.
        if text.uppercased().contains("BUFFER FULL") {
            bufferFullCount += 1
        }

        pendingRawLogBatch.append(text)
        if pendingRawLogBatch.count > 200 {
            pendingRawLogBatch.removeFirst(pendingRawLogBatch.count - 200)
        }
        uiDirty = true

        guard !text.isEmpty else { return }
        rxBuffer += text

        // Hard safety cap: if the buffer ever grows past this, the adapter isn't
        // sending the line terminators we split on — keep only the tail so we
        // never overflow, and so parsing can re-sync on the next real delimiter.
        if rxBuffer.count > 4096 {
            rxBuffer = String(rxBuffer.suffix(2048))
        }

        if rxBuffer.contains(">") {
            isWaitingForResponse = false
            processQueueIfIdle()
        }

        // Split on CR *or* LF — some adapters use one, some the other, some both.
        // Replace both with a single separator, then process complete lines.
        let normalized = rxBuffer.replacingOccurrences(of: "\n", with: "\r")
        let segments = normalized.components(separatedBy: "\r")
        // All but the last segment are complete lines; the last is a partial
        // that we keep buffered until its terminator arrives.
        for line in segments.dropLast() {
            parseLine(line)
        }
        rxBuffer = segments.last ?? ""
    }
}
