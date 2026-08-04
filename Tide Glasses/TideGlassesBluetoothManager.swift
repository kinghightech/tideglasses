//
//  TideGlassesBluetoothManager.swift
//  Tide Glasses
//
//  BLE connection, battery-status, and photo-capture layer for AIMB-G2 / HeyCyan glasses.
//  Protocol UUID and packet mapping credited in ATTRIBUTION.md.
//

import Combine
import CoreBluetooth
import Foundation

struct TideGlassesWiFiCredentials: Sendable, Equatable {
    let ssid: String
    let password: String
}

enum TideGlassesBluetoothError: LocalizedError {
    case notReady(String)
    case requestTimedOut
    case disconnected
    case invalidWiFiCredentials

    var errorDescription: String? {
        switch self {
        case .notReady(let message): message
        case .requestTimedOut: "The glasses did not report a Wi-Fi server address after 10 status checks. Power them off and on once, then try again."
        case .disconnected: "The glasses disconnected before Wi-Fi transfer was ready."
        case .invalidWiFiCredentials: "The glasses returned Wi-Fi information Tide Glass could not read."
        }
    }
}

final class TideGlassesBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothStateDescription = "Starting…"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var discoveredName: String?
    @Published private(set) var rssi: Int?
    @Published private(set) var hardwareRevision: String?
    @Published private(set) var firmwareRevision: String?
    @Published private(set) var systemID: String?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isCharging: Bool?
    @Published private(set) var isRefreshingBattery = false
    @Published private(set) var lastBatteryUpdate: Date?
    @Published private(set) var isTakingPhoto = false
    @Published private(set) var lastPhotoCapture: Date?
    @Published private(set) var photoStatus = "Ready"
    @Published private(set) var lastPhotoProtocolReply: String?
    @Published private(set) var isRequestingWiFiTransfer = false
    @Published private(set) var wifiTransferSSID: String?
    @Published private(set) var wifiDeviceIP: String?
    @Published private(set) var wifiTransferStatus = "Ready"
    @Published private(set) var lastWiFiProtocolReply: String?
    @Published private(set) var wifiProtocolTrace: [String] = []
    @Published private(set) var serviceUUIDs = Set<String>()
    @Published private(set) var characteristicUUIDs = [String: Set<String>]()
    @Published private(set) var status = "Waiting for Bluetooth"
    @Published private(set) var errorMessage: String?

    private var central: CBCentralManager!
    private var discoveredPeripheral: CBPeripheral?
    private var pendingServiceDiscovery = Set<String>()
    private var serialWriteCharacteristic: CBCharacteristic?
    private var serialNotifyCharacteristic: CBCharacteristic?
    private var receiveBuffer = Data()
    private var batteryRequestGeneration = 0
    private var photoRequestGeneration = 0
    private var wifiRequestGeneration = 0
    private var wifiIPQueryAttempt = 0
    private var wifiIPConfirmationAttempt = 0
    private var wifiIPQueryScheduleGeneration = 0
    private var hasInitialWiFiReadyIP = false
    private var wifiStartupStage: UInt8?
    private var isWiFiStartupStageReady = false
    private var wifiHotspotEarliestJoinDate: Date?
    private var hasRequestedWiFiDeviceConfig = false
    private var hasVerifiedWiFiDeviceConfig = false
    private var wifiRequestCompletion: ((Result<TideGlassesWiFiCredentials, Error>) -> Void)?
    private var pendingWiFiCredentials: TideGlassesWiFiCredentials?
    private var userInitiatedDisconnect = false
    private var hasAttemptedLaunchScan = false
    private var wifiKeepAliveTimer: Timer?
    private var autoReconnectTimer: Timer?

    private var isAutomatedWiFiTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-wifi-test")
    }

    private var isPassiveProtocolTrace: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-passive-sniff")
    }

    private var isWiFiTransferResetTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-wifi-reset")
    }

    private var isDeviceRestartTest: Bool {
        ProcessInfo.processInfo.arguments.contains("--tide-device-restart")
    }

    private var shouldConnectAutomatically: Bool {
        isAutomatedWiFiTest
            || isPassiveProtocolTrace
            || isWiFiTransferResetTest
            || isDeviceRestartTest
            || isAutoConnectEnabled
    }

    /// Mirrors the vendor app: once the glasses have been paired, every
    /// launch and foreground quietly reconnects without the user asking.
    private var isAutoConnectEnabled: Bool {
        UserDefaults.standard.object(forKey: "tide.autoConnect") as? Bool ?? true
    }

    /// Called when the app comes to the foreground.
    func reconnectIfNeeded() {
        guard canScan, !isConnected, !isConnecting, !isScanning else { return }
        startScan()
    }

    /// Keeps hunting for the glasses the whole time they are away — if they
    /// are switched off, the app picks them up on its own the moment they
    /// come back, without the user pressing anything.
    private func startAutoReconnectLoop() {
        guard autoReconnectTimer == nil else { return }
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let self, self.isAutoConnectEnabled else { return }
            self.reconnectIfNeeded()
        }
    }

    private enum UUIDs {
        static let mainService = "AE30"
        static let mainCharacteristics: Set<String> = ["AE01", "AE02", "AE03", "AE04", "AE05", "AE10"]

        static let smallDataService = "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E"
        static let smallDataCharacteristics: Set<String> = [
            "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
            "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
        ]

        static let serialDataService = "DE5BF728-D711-4E47-AF26-65E3012A5DC7"
        static let serialDataCharacteristics: Set<String> = [
            "DE5BF72A-D711-4E47-AF26-65E3012A5DC7",
            "DE5BF729-D711-4E47-AF26-65E3012A5DC7"
        ]
        static let serialWrite = "DE5BF72A-D711-4E47-AF26-65E3012A5DC7"
        static let serialNotify = "DE5BF729-D711-4E47-AF26-65E3012A5DC7"

        static let knownServices: Set<String> = [
            "AE30",
            smallDataService,
            serialDataService,
            "AE3A",
            "3802",
            "7905FFF0-B5CE-4E99-A40F-4B1E122D00D0"
        ]

        static let readableDeviceInformation: Set<String> = ["2A23", "2A25", "2A26", "2A27"]
    }

    private enum ProtocolValue {
        static let magic: UInt8 = 0xBC
        static let glassesControlCommand: UInt8 = 0x41
        static let batteryCommand: UInt8 = 0x42
        static let deviceConfigCommand: UInt8 = 0x47
        static let dataReportingCommand: UInt8 = 0x73
        static let batteryEvent: UInt8 = 0x05
        static let wifiIPEvent: UInt8 = 0x08
        static let photoMode: UInt8 = 0x01
        static let aiPhotoMode: UInt8 = 0x06
        static let transferMode: UInt8 = 0x04
        static let transferStopMode: UInt8 = 0x09
        static let defaultWiFiPassword = "123456789"
        /// Largest real packet is a ~1 KB photo chunk; anything beyond this is
        /// a corrupt length field, not a big message.
        static let maximumPacketBytes = 4096
    }

    /// Read-only tap on every packet that passes its integrity check, in
    /// arrival order. Additive by design: it is called before the existing
    /// branches and must never alter them, so new features (the voice trigger)
    /// can observe the stream without touching the transfer path.
    var onPacket: ((UInt8, Data) -> Void)?

    /// Sends one framed command on behalf of the AI vision path.
    ///
    /// A thin pass-through to the existing writer — it adds no state and keeps
    /// no session. The guard is the point: a photo pull must never interleave
    /// with a Wi-Fi transfer negotiation, which is the fragile part of this
    /// file. Everything else in the AI feature is read-only.
    @discardableResult
    func sendVisionCommand(command: UInt8, payload: Data) -> Bool {
        guard !isRequestingWiFiTransfer else { return false }
        return sendFramedCommand(command: command, payload: payload)
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var canScan: Bool {
        central?.state == .poweredOn
    }

    var hasCompatibleName: Bool {
        guard let name = discoveredName?.lowercased() else { return false }
        return ["aimb", "m02s", "a02s", "heycyan", "cyan"].contains { name.contains($0) }
    }

    var hasMainServiceMap: Bool {
        let service = expandedUUID(UUIDs.mainService)
        let found = characteristicUUIDs[service] ?? []
        return serviceUUIDs.contains(service) && UUIDs.mainCharacteristics.map(expandedUUID).allSatisfy(found.contains)
    }

    var hasSmallDataChannel: Bool {
        let service = expandedUUID(UUIDs.smallDataService)
        let found = characteristicUUIDs[service] ?? []
        return serviceUUIDs.contains(service) && UUIDs.smallDataCharacteristics.allSatisfy(found.contains)
    }

    var hasSerialDataChannel: Bool {
        let service = expandedUUID(UUIDs.serialDataService)
        let found = characteristicUUIDs[service] ?? []
        return serviceUUIDs.contains(service) && UUIDs.serialDataCharacteristics.allSatisfy(found.contains)
    }

    var isCompatibilityConfirmed: Bool {
        hasCompatibleName && hasMainServiceMap && hasSmallDataChannel && hasSerialDataChannel
    }

    var canRefreshBattery: Bool {
        isConnected
            && serialWriteCharacteristic != nil
            && serialNotifyCharacteristic?.isNotifying == true
            && !isRefreshingBattery
    }

    var canTakePhoto: Bool {
        isConnected
            && serialWriteCharacteristic != nil
            && serialNotifyCharacteristic?.isNotifying == true
            && !isTakingPhoto
            && !isRequestingWiFiTransfer
    }

    var canRequestWiFiTransfer: Bool {
        isConnected
            && serialWriteCharacteristic != nil
            && serialNotifyCharacteristic?.isNotifying == true
            && !isTakingPhoto
            && !isRefreshingBattery
            && !isRequestingWiFiTransfer
    }

    func startScan() {
        guard canScan else {
            errorMessage = "Turn on Bluetooth before scanning."
            return
        }

        resetDiscoveryResults()
        errorMessage = nil

        // A peripheral that another iOS app already connected may stop
        // advertising, so a scan alone cannot see it. Recover connected
        // HeyCyan peripherals by the services AIMB-G2 already confirmed.
        if adoptConnectedHeyCyanPeripheral() {
            return
        }

        isScanning = true
        status = "Searching for glasses…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.isScanning else { return }
            self.stopScan()
            guard self.discoveredPeripheral == nil else { return }
            if self.isAutoConnectEnabled {
                // The reconnect loop tries again shortly; stay quiet about it.
                self.status = "Waiting for glasses"
            } else {
                self.status = "No compatible glasses found"
                self.errorMessage = "Keep the glasses on and disconnect them from Cyan Glasses, then scan again."
            }
        }
    }

    private func adoptConnectedHeyCyanPeripheral() -> Bool {
        let serviceUUIDs = [
            CBUUID(string: UUIDs.serialDataService),
            CBUUID(string: UUIDs.smallDataService),
            CBUUID(string: UUIDs.mainService)
        ]

        guard let peripheral = central.retrieveConnectedPeripherals(withServices: serviceUUIDs).first else {
            return false
        }

        discoveredPeripheral = peripheral
        discoveredName = peripheral.name ?? "Connected HeyCyan glasses"
        status = "Found \(discoveredName ?? "glasses")"
        print("TideGlass recovered connected BLE peripheral: \(discoveredName ?? peripheral.identifier.uuidString)")

        if shouldConnectAutomatically {
            DispatchQueue.main.async { [weak self] in
                self?.connect()
            }
        }
        return true
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if discoveredPeripheral == nil {
            status = "Scan stopped"
        }
    }

    func connect() {
        guard let peripheral = discoveredPeripheral else { return }
        stopScan()
        userInitiatedDisconnect = false
        isConnecting = true
        errorMessage = nil
        status = "Connecting…"
        central.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = discoveredPeripheral else { return }
        userInitiatedDisconnect = true
        central.cancelPeripheralConnection(peripheral)
    }

    func refreshBattery() {
        guard isConnected,
              serialWriteCharacteristic != nil,
              serialNotifyCharacteristic?.isNotifying == true else {
            errorMessage = "Battery status is not ready yet. Reconnect the glasses and try again."
            return
        }

        batteryRequestGeneration += 1
        let requestGeneration = batteryRequestGeneration
        isRefreshingBattery = true
        errorMessage = nil
        status = "Reading battery…"

        // The official app sends a one-byte payload here, not an empty one.
        guard sendFramedCommand(command: ProtocolValue.batteryCommand, payload: Data([0x01])) else {
            isRefreshingBattery = false
            status = "Connected"
            errorMessage = "Battery status is not ready yet. Reconnect the glasses and try again."
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  self.isRefreshingBattery,
                  self.batteryRequestGeneration == requestGeneration else { return }
            self.isRefreshingBattery = false
            self.status = "Connected"
            self.errorMessage = "The battery request timed out. The glasses may have powered off."
        }
    }

    func takePhoto() {
        guard canTakePhoto else {
            errorMessage = "Photo capture is not ready yet. Reconnect the glasses and try again."
            return
        }

        photoRequestGeneration += 1
        let requestGeneration = photoRequestGeneration
        isTakingPhoto = true
        photoStatus = "Taking photo…"
        lastPhotoProtocolReply = nil
        errorMessage = nil
        status = "Taking photo…"

        let payload = Data([0x02, 0x01, ProtocolValue.photoMode])
        guard sendFramedCommand(command: ProtocolValue.glassesControlCommand, payload: payload) else {
            isTakingPhoto = false
            photoStatus = "Photo request failed"
            status = "Connected"
            errorMessage = "The photo request could not be sent."
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self,
                  self.isTakingPhoto,
                  self.photoRequestGeneration == requestGeneration else { return }
            self.isTakingPhoto = false
            self.photoStatus = "Photo command sent; storage confirmation unavailable"
            self.status = "Connected"
            self.errorMessage = nil
        }
    }

    func requestWiFiTransfer(
        completion: @escaping (Result<TideGlassesWiFiCredentials, Error>) -> Void
    ) {
        guard canRequestWiFiTransfer else {
            completion(.failure(TideGlassesBluetoothError.notReady(
                "Connect the glasses and wait for battery status before opening the gallery."
            )))
            return
        }

        wifiRequestGeneration += 1
        let requestGeneration = wifiRequestGeneration
        wifiRequestCompletion = completion
        pendingWiFiCredentials = nil
        wifiIPQueryAttempt = 0
        wifiIPConfirmationAttempt = 0
        wifiIPQueryScheduleGeneration += 1
        hasInitialWiFiReadyIP = false
        wifiStartupStage = nil
        isWiFiStartupStageReady = false
        wifiHotspotEarliestJoinDate = nil
        hasRequestedWiFiDeviceConfig = false
        hasVerifiedWiFiDeviceConfig = false
        isRequestingWiFiTransfer = true
        wifiTransferSSID = nil
        wifiDeviceIP = nil
        lastWiFiProtocolReply = nil
        wifiProtocolTrace = []
        wifiTransferStatus = "Starting glasses Wi-Fi…"
        errorMessage = nil
        status = "Starting glasses Wi-Fi…"

        // Replay of the official app's captured session, in its exact order
        // and pacing:
        //   1. transfer-stop, so a half-started Wi-Fi module is reset first
        //      (the official app closes every session this way; skipping it
        //      leaves the radio wedged for every later attempt),
        //   2. the opening handshake, one command at a time,
        //   3. the four-byte start command.
        wifiTransferStatus = "Preparing glasses…"
        performConnectHandshake()

        // Give the Bluetooth link a few seconds of silence before the start
        // command. iOS relaxes an idle connection, and this firmware shares
        // one antenna between Bluetooth and Wi-Fi.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self,
                  self.isRequestingWiFiTransfer,
                  self.wifiRequestGeneration == requestGeneration else { return }
            self.wifiTransferStatus = "Starting glasses Wi-Fi…"
            self.recordWiFiProtocol("TX 0x41  02 01 04 02  (start transfer mode)")
            guard self.sendFramedCommand(
                command: ProtocolValue.glassesControlCommand,
                payload: Data([0x02, 0x01, ProtocolValue.transferMode, 0x02])
            ) else {
                self.finishWiFiRequest(.failure(TideGlassesBluetoothError.notReady(
                    "The Wi-Fi transfer request could not be sent."
                )))
                return
            }
        }

        // The official app stays completely silent from here until the
        // glasses push 0x73 event 0x08 (hotspot live, ~19 s). Do not poll the
        // IP during startup — that traffic is absent from every successful
        // capture. The event itself completes this request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self,
                  self.isRequestingWiFiTransfer,
                  self.wifiRequestGeneration == requestGeneration else { return }
            if let credentials = self.pendingWiFiCredentials, self.wifiDeviceIP != nil {
                self.recordWiFiProtocol("TIMEOUT — joining with received credentials anyway")
                self.finishWiFiRequest(.success(credentials))
            } else {
                self.finishWiFiRequest(.failure(TideGlassesBluetoothError.requestTimedOut))
            }
        }
    }

    /// Opening handshake captured from the official app, sent once the
    /// notification channel is live: version, BCD time sync, device config,
    /// media counts, battery. The firmware appears to expect this before it
    /// will bring its Wi-Fi module up.
    private func performConnectHandshake() {
        // Paced ~150 ms apart. The official app waits for each reply before
        // sending the next; firing all five inside one connection interval is
        // not something this firmware is ever asked to handle.
        let steps: [(UInt8, Data)] = [
            (0x43, Data([0x01])),
            (0x40, bcdTimeSyncPayload()),
            (ProtocolValue.deviceConfigCommand, Data([0x01])),
            (ProtocolValue.glassesControlCommand, Data([0x02, 0x04])),
            (ProtocolValue.batteryCommand, Data([0x01]))
        ]
        recordWiFiProtocol("TX handshake  43 / 40 / 47 / 41 02 04 / 42")
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.15) { [weak self] in
                guard let self, self.isConnected else { return }
                _ = self.sendFramedCommand(command: step.0, payload: step.1)
            }
        }
    }

    /// [YY MM DD HH MM SS] in binary-coded decimal, plus the three trailing
    /// bytes the official app sends verbatim.
    private func bcdTimeSyncPayload() -> Data {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date()
        )
        func bcd(_ value: Int) -> UInt8 {
            UInt8(((value / 10) << 4) | (value % 10))
        }
        return Data([
            bcd((parts.year ?? 2026) % 100),
            bcd(parts.month ?? 1),
            bcd(parts.day ?? 1),
            bcd(parts.hour ?? 0),
            bcd(parts.minute ?? 0),
            bcd(parts.second ?? 0),
            0x01, 0x29, 0x02
        ])
    }

    /// The glasses firmware ends an idle Wi-Fi session on its own (event
    /// 0x73 09 FF 02 observed ~40 s after the last download), which killed
    /// video imports mid-browse. A periodic read-only IP query keeps the
    /// session alive while the gallery is open.
    func startWiFiSessionKeepAlive() {
        stopWiFiSessionKeepAlive()
        wifiKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isConnected, !self.isRequestingWiFiTransfer else { return }
            _ = self.sendFramedCommand(
                command: ProtocolValue.glassesControlCommand,
                payload: Data([0x02, 0x03])
            )
        }
    }

    func stopWiFiSessionKeepAlive() {
        wifiKeepAliveTimer?.invalidate()
        wifiKeepAliveTimer = nil
    }

    /// Closes the glasses Wi-Fi session with transfer-stop (02 01 09), which
    /// the official app sends at the end of every session it opens. Leaving a
    /// session unclosed is what leaves the Wi-Fi module unable to start again.
    func stopWiFiTransfer() {
        guard isConnected, serialWriteCharacteristic != nil else { return }
        recordWiFiProtocol("TX 0x41  02 01 09  (stop transfer mode)")
        _ = sendFramedCommand(
            command: ProtocolValue.glassesControlCommand,
            payload: Data([0x02, 0x01, ProtocolValue.transferStopMode])
        )
    }

    private func resetDiscoveryResults() {
        if let peripheral = discoveredPeripheral, peripheral.state == .connected {
            central.cancelPeripheralConnection(peripheral)
        }
        discoveredPeripheral = nil
        discoveredName = nil
        rssi = nil
        hardwareRevision = nil
        firmwareRevision = nil
        systemID = nil
        batteryLevel = nil
        isCharging = nil
        isRefreshingBattery = false
        lastBatteryUpdate = nil
        isTakingPhoto = false
        lastPhotoCapture = nil
        photoStatus = "Ready"
        lastPhotoProtocolReply = nil
        if wifiRequestCompletion != nil {
            finishWiFiRequest(.failure(TideGlassesBluetoothError.disconnected))
        }
        isRequestingWiFiTransfer = false
        pendingWiFiCredentials = nil
        wifiIPQueryAttempt = 0
        wifiIPConfirmationAttempt = 0
        wifiIPQueryScheduleGeneration += 1
        hasInitialWiFiReadyIP = false
        wifiStartupStage = nil
        isWiFiStartupStageReady = false
        wifiHotspotEarliestJoinDate = nil
        hasRequestedWiFiDeviceConfig = false
        hasVerifiedWiFiDeviceConfig = false
        wifiTransferSSID = nil
        wifiDeviceIP = nil
        wifiTransferStatus = "Ready"
        lastWiFiProtocolReply = nil
        wifiProtocolTrace = []
        serviceUUIDs = []
        characteristicUUIDs = [:]
        pendingServiceDiscovery = []
        serialWriteCharacteristic = nil
        serialNotifyCharacteristic = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        batteryRequestGeneration += 1
        photoRequestGeneration += 1
        wifiRequestGeneration += 1
        isConnecting = false
        isConnected = false
    }

    private func isCompatibleAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        let advertisedName = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").lowercased()
        if ["aimb", "m02s", "a02s", "heycyan", "cyan", "glasses"].contains(where: advertisedName.contains) {
            return true
        }

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return advertisedServices.contains { UUIDs.knownServices.contains(expandedUUID($0.uuidString)) }
    }

    private func expandedUUID(_ value: String) -> String {
        let upper = value.uppercased()
        if upper.count == 4 {
            return "0000\(upper)-0000-1000-8000-00805F9B34FB"
        }
        return upper
    }

    private func finishServiceDiscoveryIfReady() {
        guard pendingServiceDiscovery.isEmpty else { return }
        if isCompatibilityConfirmed {
            guard let peripheral = discoveredPeripheral,
                  let notifyCharacteristic = serialNotifyCharacteristic else {
                status = "Connected; battery channel unavailable"
                errorMessage = "The HeyCyan service map matched, but its battery notification channel was unavailable."
                return
            }

            status = "Preparing live status…"

            // The official app subscribes to every notify/indicate
            // characteristic the glasses expose — AE02, AE04, AE05, the
            // small-data channel and the serial channel — before it issues
            // any command. This firmware appears to gate its Wi-Fi start on
            // that full subscription set, so mirror it exactly. The serial
            // channel is subscribed last so its callback still drives setup.
            for service in peripheral.services ?? [] {
                for characteristic in service.characteristics ?? [] {
                    guard characteristic !== notifyCharacteristic,
                          characteristic.properties.contains(.notify)
                            || characteristic.properties.contains(.indicate) else { continue }
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        } else {
            status = "Connected; service map differs"
            errorMessage = "The glasses connected, but one or more expected HeyCyan characteristics were not found."
        }
    }

    private func handleSerialNotification(_ data: Data) {
        // A packet bigger than one BLE notification arrives in fragments: the
        // 0xFD photo chunks are ~1 KB and take about five each. A continuation
        // fragment can begin with 0xBC purely by coincidence — JPEG bytes are
        // arbitrary — and treating that as the start of a new packet discards
        // the half-assembled chunk and wedges the reader. At ~108 continuation
        // fragments per photo that lost roughly a third of all captures.
        //
        // So 0xBC only starts a packet when no packet is already in flight.
        // Single-notification packets, which is everything the transfer path
        // exchanges, behave exactly as before.
        if receiveBuffer.isEmpty {
            guard data.first == ProtocolValue.magic else { return }
            receiveBuffer = data
        } else {
            receiveBuffer.append(data)
        }

        // A corrupted length field must never wedge the channel for good.
        if receiveBuffer.count > ProtocolValue.maximumPacketBytes {
            receiveBuffer = Data()
            return
        }

        while receiveBuffer.count >= 6 {
            guard receiveBuffer.first == ProtocolValue.magic else {
                receiveBuffer.removeFirst()
                continue
            }

            let payloadLength = Int(receiveBuffer[2]) | (Int(receiveBuffer[3]) << 8)
            let packetLength = 6 + payloadLength
            guard receiveBuffer.count >= packetLength else { return }

            let packet = Data(receiveBuffer.prefix(packetLength))
            receiveBuffer.removeFirst(packetLength)
            processPacket(packet)
        }
    }

    private func processPacket(_ packet: Data) {
        guard packet.count >= 6, packet[0] == ProtocolValue.magic else { return }

        let command = packet[1]
        let payloadLength = Int(packet[2]) | (Int(packet[3]) << 8)
        guard packet.count >= 6 + payloadLength else { return }

        let payload = Data(packet[6..<(6 + payloadLength)])
        let receivedCRC = UInt16(packet[4]) | (UInt16(packet[5]) << 8)
        let expectedCRC = payload.isEmpty ? 0xFFFF : crc16Modbus(payload)
        guard receivedCRC == expectedCRC else {
            errorMessage = "Ignored a glasses response that failed its integrity check."
            return
        }

        onPacket?(command, payload)

        if isPassiveProtocolTrace {
            print(
                "TideGlass PASSIVE RX 0x\(String(format: "%02X", command)) "
                + "payload: \(hexString(payload))"
            )
        }

        if isRequestingWiFiTransfer {
            recordWiFiProtocol("RX 0x\(String(format: "%02X", command))  \(hexString(payload))")
        }

        if command == ProtocolValue.glassesControlCommand {
            handleGlassesControlResponse(payload)
            return
        }

        if command == ProtocolValue.deviceConfigCommand {
            return
        }

        if command == ProtocolValue.dataReportingCommand {
            handleDataReporting(payload)
            return
        }

        if command == ProtocolValue.batteryCommand, payload.count >= 2 {
            updateBattery(level: Int(payload[0]), charging: payload[1] != 0)
            return
        }

        // Vendor device notifications normally put the event at payload[0].
        // Some SDK wrappers retain an extra six-byte prefix, so accept both.
        if payload.count >= 3, payload[0] == ProtocolValue.batteryEvent {
            updateBattery(level: Int(payload[1]), charging: payload[2] != 0)
        } else if payload.count > 8, payload[6] == ProtocolValue.batteryEvent {
            updateBattery(level: Int(payload[7]), charging: payload[8] != 0)
        }

        if payload.count >= 5, payload[0] == ProtocolValue.wifiIPEvent {
            updateWiFiDeviceIP(bytes: payload[1...4])
        } else if payload.count > 10, payload[6] == ProtocolValue.wifiIPEvent {
            updateWiFiDeviceIP(bytes: payload[7...10])
        }
    }

    private func handleGlassesControlResponse(_ payload: Data) {
        let reply = hexString(payload)
        TideDiagnostics.log("RX 0x41 payload: \(reply)")

        if isRequestingWiFiTransfer {
            if let credentials = parseWiFiCredentials(payload) {
                lastWiFiProtocolReply = "0x41  transfer credentials received"
                wifiTransferSSID = credentials.ssid
                pendingWiFiCredentials = credentials
                wifiTransferStatus = "Credentials received. Joining…"
                recordWiFiProtocol("CREDENTIALS — starting join immediately")
                // Hand the credentials over the moment they arrive. Waiting
                // for the hotspot-live event means never attempting a join at
                // all when that event does not come; the join layer retries
                // on its own for as long as the hotspot may take to appear.
                finishWiFiRequest(.success(credentials))
                return
            }

            if payload.count >= 3,
               payload[0] == 0x02,
               payload[1] == 0x01,
               payload[2] == ProtocolValue.transferMode {
                lastWiFiProtocolReply = "0x41  transfer mode acknowledged"
                wifiTransferStatus = "Waiting for hotspot credentials…"
                return
            }
        }

        if payload.count >= 6, payload[0] == 0x02, payload[1] == 0x03 {
            updateWiFiDeviceIP(bytes: payload[2...5])
            return
        }

        // Vendor implementations expose both a four-byte response
        // [02, dataType, workType, status] and an extended response whose
        // current work type follows the status byte. AIMB firmware revisions
        // do not all interpret the fourth byte identically, so a non-zero
        // value is not enough by itself to declare that a photo failed.
        guard payload.count >= 3, payload[0] == 0x02, payload[1] == 0x01 else { return }

        let reportedWorkType = payload[2]
        let activeWorkType = payload.count >= 5 ? payload[4] : nil
        let isPhotoReply = isPhotoMode(reportedWorkType)
            || activeWorkType.map(isPhotoMode) == true
        guard isTakingPhoto, isPhotoReply else { return }

        lastPhotoProtocolReply = "0x41  \(reply)"

        status = "Connected"
        if payload.count >= 4, payload[3] == 0 {
            completePhotoCapture()
        } else {
            // Keep waiting briefly for the separate media-update event. Never
            // retry a capture automatically: the shutter may already have fired.
            photoStatus = "Glasses received the command; checking storage…"
            errorMessage = nil
        }
    }

    private func handleDataReporting(_ payload: Data) {
        let reply = hexString(payload)
        TideDiagnostics.log("RX 0x73 payload: \(reply)")

        // 0x0B ticks are a free-running progress counter, not fixed stages.
        // Never gate the join on them; the official app ignores them entirely.
        if isRequestingWiFiTransfer,
           payload.count >= 2,
           payload[0] == 0x0B {
            wifiStartupStage = payload[1]
            wifiTransferStatus = "Glasses hotspot starting…"
            return
        }

        // Firmware's "Wi-Fi transfer aborted" event. Record it, but never let
        // it cancel a join that is already in flight.
        if payload.count >= 3, payload[0] == 0x09, payload[1] == 0xFF {
            recordWiFiProtocol("ABORT  09 FF \(String(format: "%02X", payload[2]))")
            if isRequestingWiFiTransfer, pendingWiFiCredentials == nil {
                finishWiFiRequest(.failure(TideGlassesBluetoothError.notReady(
                    "The glasses did not start their Wi-Fi. Power the glasses off and on, then try again."
                )))
            }
            return
        }

        // Device notifications are delivered through command 0x73. The SDK
        // exposes the complete packet and therefore describes the event byte
        // at offset 6; this implementation has already removed that six-byte
        // frame header, so the Wi-Fi-ready event is payload[0]. Handle it
        // before the photo-only guard below.
        if payload.count >= 5, payload[0] == ProtocolValue.wifiIPEvent {
            lastWiFiProtocolReply = "0x73  Wi-Fi ready  \(reply)"
            updateWiFiDeviceIP(bytes: payload[1...4])
            return
        }

        // Keep accepting an SDK-wrapped form in case a firmware revision
        // embeds the original six-byte prefix inside the 0x73 payload.
        if payload.count > 10, payload[6] == ProtocolValue.wifiIPEvent {
            lastWiFiProtocolReply = "0x73  Wi-Fi ready (wrapped)  \(reply)"
            updateWiFiDeviceIP(bytes: payload[7...10])
            return
        }

        guard isTakingPhoto else { return }

        lastPhotoProtocolReply = "0x73  \(reply)"

        // Documented HeyCyan media-count update:
        // [01, count/status, 00, 00, 00, 00, 00, 01]
        guard payload.count >= 8, payload[0] == 0x01, payload[7] == 0x01 else { return }
        completePhotoCapture()
    }

    private func completePhotoCapture() {
        photoRequestGeneration += 1
        isTakingPhoto = false
        lastPhotoCapture = Date()
        photoStatus = "Photo captured"
        status = "Connected"
        errorMessage = nil
    }

    private func isPhotoMode(_ value: UInt8) -> Bool {
        value == ProtocolValue.photoMode || value == ProtocolValue.aiPhotoMode
    }

    private func parseWiFiCredentials(_ payload: Data) -> TideGlassesWiFiCredentials? {
        // HeyCyan transfer response:
        // [02, 01, 04, status, ssidLengthLE16, passwordLengthLE16, ssid, password]
        guard payload.count >= 8,
              payload[0] == 0x02,
              payload[1] == 0x01,
              payload[2] == ProtocolValue.transferMode else { return nil }

        let ssidLength = Int(payload[4]) | (Int(payload[5]) << 8)
        let passwordLength = Int(payload[6]) | (Int(payload[7]) << 8)
        let expectedLength = 8 + ssidLength + passwordLength
        guard (1...64).contains(ssidLength),
              (0...64).contains(passwordLength),
              payload.count >= expectedLength else { return nil }

        let ssidStart = 8
        let passwordStart = ssidStart + ssidLength
        guard let ssid = String(
            data: Data(payload[ssidStart..<passwordStart]),
            encoding: .utf8
        )?.trimmingCharacters(in: .controlCharacters),
              !ssid.isEmpty else { return nil }

        let reportedPassword = String(
            data: Data(payload[passwordStart..<expectedLength]),
            encoding: .utf8
        )?.trimmingCharacters(in: .controlCharacters) ?? ""

        // The vendor iOS demo documents that M02S/AIMB firmware can return an
        // incorrect password even though this fixed password is configured.
        let knownHeyCyanSSID = ["M02S", "AIMB", "A02S"].contains {
            ssid.uppercased().contains($0)
        }
        let password: String
        if knownHeyCyanSSID || !(8...63).contains(reportedPassword.count) {
            password = ProtocolValue.defaultWiFiPassword
        } else {
            password = reportedPassword
        }

        return TideGlassesWiFiCredentials(ssid: ssid, password: password)
    }

    private func updateWiFiDeviceIP(bytes: Data.SubSequence) {
        guard bytes.count == 4 else { return }
        let ip = bytes.map(String.init).joined(separator: ".")
        guard ip != "0.0.0.0" else { return }
        wifiDeviceIP = ip
        TideDiagnostics.log("Wi-Fi device IP: \(ip)")

        guard isRequestingWiFiTransfer else {
            wifiTransferStatus = "Glasses Wi-Fi ready at \(ip)"
            return
        }

        // This arrives as a pushed 0x73 event only once the radio is actually
        // live — the same signal the official app waits for. Join now.
        guard let credentials = pendingWiFiCredentials else { return }
        wifiTransferStatus = "Glasses hotspot live at \(ip)"
        recordWiFiProtocol("HOTSPOT LIVE  \(ip)")
        finishWiFiRequest(.success(credentials))
    }

    private func finishWiFiRequest(_ result: Result<TideGlassesWiFiCredentials, Error>) {
        guard let completion = wifiRequestCompletion else { return }
        wifiRequestCompletion = nil
        pendingWiFiCredentials = nil
        wifiIPQueryAttempt = 0
        wifiIPConfirmationAttempt = 0
        wifiIPQueryScheduleGeneration += 1
        hasInitialWiFiReadyIP = false
        wifiStartupStage = nil
        isWiFiStartupStageReady = false
        wifiHotspotEarliestJoinDate = nil
        hasRequestedWiFiDeviceConfig = false
        hasVerifiedWiFiDeviceConfig = false
        wifiRequestGeneration += 1
        isRequestingWiFiTransfer = false
        status = isConnected ? "Connected" : "Disconnected"

        if case .failure(let error) = result {
            wifiTransferStatus = "Wi-Fi transfer unavailable"
            errorMessage = error.localizedDescription
            // Always close a failed session so the Wi-Fi module is left in a
            // state the next start can work from.
            stopWiFiTransfer()
        }
        completion(result)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func recordWiFiProtocol(_ message: String) {
        TideDiagnostics.log("BLE \(message)")
        lastWiFiProtocolReply = message
        wifiProtocolTrace.append(message)
        if wifiProtocolTrace.count > 16 {
            wifiProtocolTrace.removeFirst(wifiProtocolTrace.count - 16)
        }
    }

    @discardableResult
    private func sendFramedCommand(command: UInt8, payload: Data) -> Bool {
        guard let peripheral = discoveredPeripheral,
              peripheral.state == .connected,
              let writeCharacteristic = serialWriteCharacteristic else { return false }

        let length = payload.count
        let crc = payload.isEmpty ? UInt16(0xFFFF) : crc16Modbus(payload)
        var packet = Data([
            ProtocolValue.magic,
            command,
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF)
        ])
        packet.append(payload)

        let writeType: CBCharacteristicWriteType = writeCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(packet, for: writeCharacteristic, type: writeType)
        return true
    }

    private func updateBattery(level: Int, charging: Bool) {
        guard (0...100).contains(level) else {
            errorMessage = "The glasses returned an invalid battery percentage."
            isRefreshingBattery = false
            return
        }

        batteryRequestGeneration += 1
        batteryLevel = level
        isCharging = charging
        lastBatteryUpdate = Date()
        isRefreshingBattery = false
        errorMessage = nil
        status = "Connected"
    }

    private func crc16Modbus(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}

extension TideGlassesBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStateDescription = "On"
            status = "Ready to scan"
            if !hasAttemptedLaunchScan, discoveredPeripheral == nil {
                hasAttemptedLaunchScan = true
                startScan()
            }
            startAutoReconnectLoop()
        case .poweredOff:
            bluetoothStateDescription = "Off"
            status = "Bluetooth is off"
            isScanning = false
        case .unauthorized:
            bluetoothStateDescription = "Permission needed"
            status = "Bluetooth permission is required"
        case .unsupported:
            bluetoothStateDescription = "Unsupported"
            status = "Bluetooth LE is unavailable"
        case .resetting:
            bluetoothStateDescription = "Resetting"
            status = "Bluetooth is resetting"
        case .unknown:
            bluetoothStateDescription = "Starting…"
        @unknown default:
            bluetoothStateDescription = "Unknown"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isCompatibleAdvertisement(peripheral: peripheral, advertisementData: advertisementData) else { return }

        discoveredPeripheral = peripheral
        discoveredName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Compatible glasses"
        rssi = RSSI.intValue
        status = "Found \(discoveredName ?? "glasses")"
        stopScan()

        if shouldConnectAutomatically {
            connect()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnecting = false
        isConnected = true
        userInitiatedDisconnect = false
        status = "Discovering services…"
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        isConnected = false
        status = "Connection failed"
        errorMessage = error?.localizedDescription ?? "The glasses could not be connected."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopWiFiSessionKeepAlive()
        isConnecting = false
        isConnected = false
        isRefreshingBattery = false
        isTakingPhoto = false
        if wifiRequestCompletion != nil {
            finishWiFiRequest(.failure(TideGlassesBluetoothError.disconnected))
        }
        isRequestingWiFiTransfer = false
        serialWriteCharacteristic = nil
        serialNotifyCharacteristic = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        batteryRequestGeneration += 1
        photoRequestGeneration += 1
        wifiRequestGeneration += 1
        status = "Disconnected"
        if let error {
            errorMessage = error.localizedDescription
        } else if !userInitiatedDisconnect {
            errorMessage = "The glasses disconnected. If they auto-powered off, turn them on and scan again."
        }
        userInitiatedDisconnect = false
    }
}

extension TideGlassesBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service discovery failed"
            errorMessage = error.localizedDescription
            return
        }

        let services = peripheral.services ?? []
        serviceUUIDs = Set(services.map { expandedUUID($0.uuid.uuidString) })
        pendingServiceDiscovery = serviceUUIDs

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let serviceID = expandedUUID(service.uuid.uuidString)
        defer {
            pendingServiceDiscovery.remove(serviceID)
            finishServiceDiscoveryIfReady()
        }

        if let error {
            errorMessage = "Could not inspect \(service.uuid.uuidString): \(error.localizedDescription)"
            return
        }

        let characteristics = service.characteristics ?? []
        characteristicUUIDs[serviceID] = Set(characteristics.map { expandedUUID($0.uuid.uuidString) })

        for characteristic in characteristics {
            let rawID = characteristic.uuid.uuidString.uppercased()
            let expandedID = expandedUUID(rawID)
            if expandedID == expandedUUID(UUIDs.serialWrite) {
                serialWriteCharacteristic = characteristic
            } else if expandedID == expandedUUID(UUIDs.serialNotify) {
                serialNotifyCharacteristic = characteristic
            }

            if UUIDs.readableDeviceInformation.contains(rawID), characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard expandedUUID(characteristic.uuid.uuidString) == expandedUUID(UUIDs.serialNotify) else { return }

        if let error {
            status = "Connected; live status unavailable"
            errorMessage = "Could not enable the battery response channel: \(error.localizedDescription)"
            return
        }

        guard characteristic.isNotifying else {
            status = "Connected; live status unavailable"
            errorMessage = "The battery response channel did not activate."
            return
        }

        status = "Connected"
        performConnectHandshake()
        if isDeviceRestartTest {
            print("TideGlass device restart TX 0x41 payload: 02 01 0E")
            _ = sendFramedCommand(
                command: ProtocolValue.glassesControlCommand,
                payload: Data([0x02, 0x01, 0x0E])
            )
            return
        }
        if isWiFiTransferResetTest {
            print("TideGlass P2P restart TX 0x41 payload: 02 01 0F")
            _ = sendFramedCommand(
                command: ProtocolValue.glassesControlCommand,
                payload: Data([0x02, 0x01, 0x0F])
            )
            return
        }
        if isPassiveProtocolTrace {
            print("TideGlass passive protocol trace ready")
            return
        }
        refreshBattery()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if expandedUUID(characteristic.uuid.uuidString) == expandedUUID(UUIDs.serialNotify) {
                isRefreshingBattery = false
                status = "Connected"
                errorMessage = "Could not read battery status: \(error.localizedDescription)"
            }
            return
        }

        guard let data = characteristic.value else { return }

        if expandedUUID(characteristic.uuid.uuidString) == expandedUUID(UUIDs.serialNotify) {
            handleSerialNotification(data)
            return
        }

        switch characteristic.uuid.uuidString.uppercased() {
        case "2A26":
            firmwareRevision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        case "2A27":
            hardwareRevision = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
        case "2A23":
            systemID = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard expandedUUID(characteristic.uuid.uuidString) == expandedUUID(UUIDs.serialWrite),
              let error else { return }
        isRefreshingBattery = false
        if isTakingPhoto {
            photoStatus = "Photo request failed"
        }
        isTakingPhoto = false
        if isRequestingWiFiTransfer {
            finishWiFiRequest(.failure(TideGlassesBluetoothError.notReady(
                "The glasses rejected the Wi-Fi transfer request: \(error.localizedDescription)"
            )))
        }
        status = "Connected"
        errorMessage = "Could not send a glasses command: \(error.localizedDescription)"
    }
}
