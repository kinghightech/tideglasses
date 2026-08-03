//
//  TideGlassesMediaTransferManager.swift
//  Tide Glasses
//
//  iPhone Wi-Fi gallery/import flow for AIMB-G2 / HeyCyan glasses.
//  Protocol and endpoint research is credited in ATTRIBUTION.md.
//

import Combine
import Foundation
import Network

#if os(iOS)
import NetworkExtension
#endif

#if canImport(Photos)
import Photos
#endif

/// Persistent on-device diagnostics. Console streaming dies whenever the
/// phone switches Wi-Fi networks, so every transfer step is also appended to
/// Documents/tide-diagnostics.log, which survives and can be pulled over USB.
enum TideDiagnostics {
    static let logFileURL: URL = {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        return documents.appendingPathComponent("tide-diagnostics.log")
    }()

    private static let queue = DispatchQueue(label: "tide.diagnostics")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)"
        print("TideGlass \(message)")
        queue.async {
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }
}

struct TideGlassesMediaItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case photo
        case video
        case audio
        case unknown
    }

    let filename: String
    let remoteURL: URL
    let kind: Kind

    var id: String { filename }

    var canImportToPhotos: Bool {
        kind == .photo || kind == .video
    }
}

enum TideGlassesMediaTransferError: LocalizedError {
    case automaticJoinUnavailable
    case glassesServerNotFound
    case serverUnreachable(String)
    case invalidManifest
    case invalidMediaResponse(String)
    case photoPermissionDenied
    case unsupportedMedia

    var errorDescription: String? {
        switch self {
        case .automaticJoinUnavailable:
            "Automatic Wi-Fi joining is unavailable. Join the glasses network in Settings, then return to Tide Glass."
        case .glassesServerNotFound:
            "Tide Glass could not reach the glasses media server. Make sure the iPhone is connected to the glasses Wi-Fi."
        case .serverUnreachable(let detail):
            "The glasses server did not answer (\(detail)). If the iPhone shows it is connected to the glasses Wi-Fi, check Settings ▸ Privacy & Security ▸ Local Network and make sure Tide Glass is allowed, then retry."
        case .invalidManifest:
            "The glasses returned a media list Tide Glass could not read."
        case .invalidMediaResponse(let filename):
            "The glasses did not return a valid copy of \(filename)."
        case .photoPermissionDenied:
            "Allow Tide Glass to add photos in Settings so imports can be saved to the iPhone gallery."
        case .unsupportedMedia:
            "This media type cannot be imported into the iPhone Photos library yet."
        }
    }
}

@MainActor
final class TideGlassesMediaTransferManager: ObservableObject {
    @Published private(set) var items: [TideGlassesMediaItem] = []
    @Published private(set) var status = "Connect the glasses to import their data."
    @Published private(set) var isBusy = false
    @Published private(set) var isImportingAll = false
    @Published private(set) var importProgress: Double = 0
    @Published private(set) var importDetail = ""
    @Published private(set) var deviceIP: String?
    @Published private(set) var hotspotSSID: String?
    @Published private(set) var hotspotPassword: String?
    @Published private(set) var needsManualWiFiJoin = false
    @Published private(set) var errorMessage: String?

    private let bluetooth: TideGlassesBluetoothManager
    private let album: TideAlbumStore
    private var transferTask: Task<Void, Never>?
    private var lastOpportunisticProbe = Date.distantPast

    private static let candidateIPs = [
        "192.168.43.1", "192.168.4.1", "192.168.31.1",
        "192.168.1.1", "192.168.0.1", "192.168.100.1",
        "192.168.123.1", "192.168.137.1", "192.168.49.1",
        "10.0.0.1", "172.20.10.1"
    ]

    init(bluetooth: TideGlassesBluetoothManager, album: TideAlbumStore) {
        self.bluetooth = bluetooth
        self.album = album
    }

    func openGallery() {
        guard !isBusy else { return }
        guard bluetooth.isConnected else {
            errorMessage = "Connect your AIMB-G2 over Bluetooth first."
            status = "Glasses are not connected."
            return
        }

        transferTask?.cancel()
        items = []
        deviceIP = nil
        needsManualWiFiJoin = false
        errorMessage = nil
        isBusy = true
        status = "Asking the glasses to start Wi-Fi…"

        // The Bluetooth layer replays the official app's captured session:
        // transfer-stop to reset the Wi-Fi module, the paced handshake, then
        // the four-byte start command.
        bluetooth.requestWiFiTransfer { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let credentials):
                self.hotspotSSID = credentials.ssid
                self.hotspotPassword = credentials.password
                self.deviceIP = self.bluetooth.wifiDeviceIP
                self.joinAndLoad(credentials: credentials)
            case .failure(let error):
                self.isBusy = false
                self.status = "Could not start glasses Wi-Fi."
                self.errorMessage = error.localizedDescription
                // Credentials from an earlier attempt may still let a
                // manual Settings join work — always offer that path.
                self.needsManualWiFiJoin = self.hotspotSSID != nil
            }
        }
    }

    func continueAfterManualJoin() {
        guard !isBusy else { return }
        errorMessage = nil
        isBusy = true
        status = "Finding the glasses media server…"

        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }
            await self.findServerAndLoadGallery(
                initialDelay: .milliseconds(300),
                maximumAttempts: 8
            )
        }
    }

    func retryAutomaticJoin() {
        guard !isBusy else { return }
        guard let ssid = hotspotSSID,
              let password = hotspotPassword else {
            openGallery()
            return
        }

        needsManualWiFiJoin = false
        errorMessage = nil
        isBusy = true
        joinAndLoad(credentials: TideGlassesWiFiCredentials(
            ssid: ssid,
            password: password
        ))
    }

    func refreshGallery() {
        guard !isBusy else { return }
        if deviceIP == nil {
            continueAfterManualJoin()
            return
        }

        errorMessage = nil
        isBusy = true
        status = "Refreshing gallery…"
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadKnownServer()
        }
    }

    /// Imports everything the glasses listed, hands-free: download each file,
    /// save photos/videos to the Photos library, keep an app-album copy, then
    /// end the Wi-Fi session so the phone returns to its normal network.
    private func startAutoImport() {
        guard !isImportingAll else { return }
        guard !items.isEmpty else {
            finishAutoImport(imported: 0, failed: 0)
            return
        }

        isImportingAll = true
        isBusy = true
        importProgress = 0
        errorMessage = nil

        let queue = items
        transferTask = Task { [weak self] in
            guard let self else { return }
            var imported = 0
            var failed = 0
            for (index, item) in queue.enumerated() where !Task.isCancelled {
                if album.contains(filename: item.filename) {
                    imported += 1
                    importProgress = Double(index + 1) / Double(queue.count)
                    continue
                }
                do {
                    try await importOne(item, index: index, total: queue.count)
                    imported += 1
                } catch {
                    failed += 1
                    TideDiagnostics.log("import \(item.filename) FAILED: \(error)")
                }
                importProgress = Double(index + 1) / Double(queue.count)
            }
            guard !Task.isCancelled else { return }
            finishAutoImport(imported: imported, failed: failed)
        }
    }

    private func importOne(
        _ item: TideGlassesMediaItem,
        index: Int,
        total: Int
    ) async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(
                URL(fileURLWithPath: item.filename).pathExtension
            )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        TideDiagnostics.log("import \(item.filename) downloading…")
        importDetail = "Item \(index + 1) of \(total)…"

        let count = Double(total)
        try await Self.downloadMediaToFile(item, destination: temporaryURL) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let fraction = expected.map {
                    $0 > 0 ? min(1, Double(received) / Double($0)) : 0
                } ?? 0
                self.importProgress = (Double(index) + fraction) / count
                if let expected {
                    self.importDetail = "Item \(index + 1) of \(total) · \(Self.byteText(received)) of \(Self.byteText(expected))"
                } else {
                    self.importDetail = "Item \(index + 1) of \(total) · \(Self.byteText(received))"
                }
            }
        }

        if item.canImportToPhotos {
            try await Self.saveToPhotos(fileURL: temporaryURL, item: item)
        }
        try album.add(fileURL: temporaryURL, filename: item.filename)
        TideDiagnostics.log("import \(item.filename) complete")
    }

    private func finishAutoImport(imported: Int, failed: Int) {
        isImportingAll = false
        importDetail = ""
        bluetooth.stopWiFiSessionKeepAlive()
        bluetooth.stopWiFiTransfer()
        #if os(iOS)
        if let ssid = hotspotSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        #endif
        deviceIP = nil
        hotspotSSID = nil
        hotspotPassword = nil
        needsManualWiFiJoin = false
        items = []
        isBusy = false
        if imported == 0, failed == 0 {
            status = "No new data on the glasses."
        } else if failed == 0 {
            status = "Imported \(imported) item\(imported == 1 ? "" : "s") from the glasses."
        } else {
            status = "Imported \(imported); \(failed) failed. Tap Import Glasses Data to retry."
            errorMessage = "Some items did not transfer. They are still on the glasses — run the import again."
        }
        TideDiagnostics.log("auto-import finished: \(imported) imported, \(failed) failed")
    }

    private static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func endWiFiSession() {
        transferTask?.cancel()
        transferTask = nil
        isBusy = false
        isImportingAll = false
        // Only clean up the phone side. Never command the glasses to stop —
        // the firmware ends its own sessions, and 02 01 09 wedges the radio.
        bluetooth.stopWiFiSessionKeepAlive()
        bluetooth.stopWiFiTransfer()
        #if os(iOS)
        if let ssid = hotspotSSID {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        #endif
        deviceIP = nil
        hotspotSSID = nil
        hotspotPassword = nil
        needsManualWiFiJoin = false
        errorMessage = nil
        status = "Glasses Wi-Fi turned off."
    }

    /// Called when the Gallery appears or the app returns to the foreground.
    /// If a Tide session is pending, resume it. Otherwise probe quietly for
    /// the glasses server anyway — the phone may already be on the glasses
    /// network via Settings or another app, and Tide should import from any
    /// live connection it finds, regardless of who established it.
    func resumeIfJoinedManually() {
        guard !isBusy, deviceIP == nil else { return }

        if hotspotSSID != nil {
            continueAfterManualJoin()
            return
        }

        guard Date().timeIntervalSince(lastOpportunisticProbe) > 10 else { return }
        lastOpportunisticProbe = Date()
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }

            var candidates = Self.candidateIPs
            if let reportedIP = bluetooth.wifiDeviceIP {
                candidates.removeAll { $0 == reportedIP }
                candidates.insert(reportedIP, at: 0)
            }

            guard let result = try? await Self.findGlassesServer(candidates: candidates),
                  !Task.isCancelled else { return }
            TideDiagnostics.log("opportunistic probe found glasses server at \(result.ip)")
            isBusy = true
            deviceIP = result.ip
            needsManualWiFiJoin = false
            status = "Found the glasses server on the current Wi-Fi. Importing…"
            applyManifest(result.manifest, ip: result.ip)
        }
    }

    private func joinAndLoad(credentials: TideGlassesWiFiCredentials) {
        transferTask?.cancel()
        transferTask = Task { [weak self] in
            guard let self else { return }
            status = "Asking iPhone to join \(credentials.ssid)…"

            // The glasses AP often starts broadcasting 10–30 seconds after
            // BLE reports it ready, so a single association attempt fails
            // even in the official app. Run up to three full
            // apply-and-associate rounds before falling back to manual join.
            var joined = false
            for round in 1...3 where !joined {
                guard !Task.isCancelled else { return }
                TideDiagnostics.log("join round \(round)/3 starting")
                do {
                    try await Self.applyHotspotConfiguration(
                        credentials,
                        removingExisting: round == 1
                    )
                } catch {
                    TideDiagnostics.log("join round \(round)/3 apply error: \(error.localizedDescription)")
                    guard round < 3 else { break }
                    status = "Glasses hotspot not visible yet. Waiting to retry… (\(round) of 3)"
                    try? await Task.sleep(for: .seconds(6))
                    continue
                }
                needsManualWiFiJoin = false
                joined = await waitForAssociation(
                    with: credentials,
                    attempts: round == 1 ? 8 : 5
                )
            }
            guard !Task.isCancelled else { return }
            TideDiagnostics.log("join phase finished, associated=\(joined)")

            if joined {
                status = "iPhone joined \(credentials.ssid). Finding the media server…"
                await findServerAndLoadGallery(
                    initialDelay: .seconds(2),
                    maximumAttempts: 6
                )
            } else {
                // The association check can stay empty in edge cases even
                // when the join worked, so probe the server before giving up.
                status = "Join not confirmed yet. Checking the glasses anyway…"
                await findServerAndLoadGallery(
                    initialDelay: .seconds(1),
                    maximumAttempts: 2
                )
            }
        }
    }

    /// Polls the phone's current Wi-Fi network until it matches the glasses
    /// hotspot. Re-applies the hotspot configuration partway through, the way
    /// the HeyCyan demo nudges iOS when association stalls in dense Wi-Fi.
    private func waitForAssociation(
        with credentials: TideGlassesWiFiCredentials,
        attempts: Int
    ) async -> Bool {
        #if os(iOS)
        for attempt in 1...attempts {
            do {
                try await Task.sleep(for: .seconds(attempt == 1 ? 2 : 3))
            } catch {
                return false
            }
            guard !Task.isCancelled else { return false }

            let current = await Self.currentWiFiSSID()
            TideDiagnostics.log(
                "association check \(attempt)/\(attempts): on \(current ?? "<no Wi-Fi reported>")"
            )
            if current == credentials.ssid {
                return true
            }
            status = "Waiting for iPhone to join \(credentials.ssid)… \(attempt) of \(attempts)"

            if attempt == 4 {
                try? await Self.applyHotspotConfiguration(
                    credentials,
                    removingExisting: false
                )
            }
        }
        return false
        #else
        return false
        #endif
    }

    private static func currentWiFiSSID() async -> String? {
        #if os(iOS)
        // Allowed without location permission because this app configured the
        // network through NEHotspotConfiguration.
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #else
        nil
        #endif
    }

    private func findServerAndLoadGallery(
        initialDelay: Duration,
        maximumAttempts: Int
    ) async {
        do {
            try await Task.sleep(for: initialDelay)
            guard !Task.isCancelled else { return }

            var lastError: Error = TideGlassesMediaTransferError.glassesServerNotFound
            for attempt in 1...maximumAttempts {
                guard !Task.isCancelled else { return }
                status = attempt == 1
                    ? "Finding the glasses media server…"
                    : "Glasses Wi-Fi is starting… attempt \(attempt) of \(maximumAttempts)"

                var candidates = Self.candidateIPs
                if let reportedIP = bluetooth.wifiDeviceIP {
                    candidates.removeAll { $0 == reportedIP }
                    candidates.insert(reportedIP, at: 0)
                }

                do {
                    let result = try await Self.findGlassesServer(candidates: candidates)
                    guard !Task.isCancelled else { return }
                    deviceIP = result.ip
                    needsManualWiFiJoin = false
                    applyManifest(result.manifest, ip: result.ip)
                    return
                } catch {
                    lastError = error
                    guard attempt < maximumAttempts else { break }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            throw lastError
        } catch {
            isBusy = false
            needsManualWiFiJoin = true
            status = "Automatic Wi-Fi connection did not finish."
            errorMessage = error.localizedDescription
        }
    }

    private func reloadKnownServer() async {
        guard let deviceIP else {
            await findServerAndLoadGallery(initialDelay: .zero, maximumAttempts: 2)
            return
        }

        do {
            let manifest = try await Self.fetchManifest(ip: deviceIP)
            guard !Task.isCancelled else { return }
            applyManifest(manifest, ip: deviceIP)
        } catch {
            isBusy = false
            status = "Gallery refresh failed."
            errorMessage = error.localizedDescription
        }
    }

    private func applyManifest(_ manifest: String, ip: String) {
        let filenames = Self.parseManifest(manifest)
        items = filenames.compactMap { filename in
            guard let url = Self.mediaURL(ip: ip, filename: filename) else { return nil }
            return TideGlassesMediaItem(
                filename: filename,
                remoteURL: url,
                kind: Self.kind(for: filename)
            )
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedDescending }

        // Hold the transfer session open while files download; the firmware
        // otherwise tears it down after ~40 idle seconds.
        bluetooth.startWiFiSessionKeepAlive()

        errorMessage = nil
        status = items.isEmpty
            ? "The glasses gallery is empty."
            : "Found \(items.count) file\(items.count == 1 ? "" : "s"). Importing…"
        startAutoImport()
    }

    private static func findGlassesServer(
        candidates: [String]
    ) async throws -> (ip: String, manifest: String) {
        let primaryIP = candidates.first
        return try await withThrowingTaskGroup(
            of: (ip: String, outcome: Result<String, Error>).self
        ) { group in
            for ip in candidates {
                group.addTask {
                    do {
                        return (ip, .success(try await fetchManifest(ip: ip)))
                    } catch {
                        return (ip, .failure(error))
                    }
                }
            }

            var primaryError: Error?
            for try await result in group {
                switch result.outcome {
                case .success(let manifest):
                    TideDiagnostics.log(
                        "probe \(result.ip) SUCCESS — manifest \(manifest.count) bytes"
                    )
                    group.cancelAll()
                    return (result.ip, manifest)
                case .failure(let error):
                    TideDiagnostics.log("probe \(result.ip) failed: \(error)")
                    if result.ip == primaryIP {
                        primaryError = error
                    }
                }
            }
            if let primaryError {
                if case NWError.posix(let code) = primaryError,
                   code == .EPERM {
                    throw TideGlassesMediaTransferError.serverUnreachable(
                        "blocked by iOS Local Network permission — enable Tide Glass under Settings ▸ Privacy & Security ▸ Local Network"
                    )
                }
                throw TideGlassesMediaTransferError.serverUnreachable(
                    primaryError.localizedDescription
                )
            }
            throw TideGlassesMediaTransferError.glassesServerNotFound
        }
    }

    private static func fetchManifest(ip: String) async throws -> String {
        let body = try await rawHTTPGet(
            ip: ip,
            path: "/files/media.config",
            timeoutSeconds: 5
        )
        guard let manifest = String(data: body, encoding: .utf8)
                ?? String(data: body, encoding: .isoLatin1),
              isPlausibleManifest(manifest) else {
            throw TideGlassesMediaTransferError.invalidManifest
        }
        return manifest
    }

    private static func downloadMedia(_ item: TideGlassesMediaItem) async throws -> Data {
        guard let host = item.remoteURL.host else {
            throw TideGlassesMediaTransferError.invalidMediaResponse(item.filename)
        }
        let data = try await rawHTTPGet(
            ip: host,
            path: item.remoteURL.path(percentEncoded: true),
            timeoutSeconds: 180
        )
        guard !data.isEmpty else {
            throw TideGlassesMediaTransferError.invalidMediaResponse(item.filename)
        }
        return data
    }

    /// Streams a media file straight to disk. Videos must reach Photos as a
    /// file (byte-based video saves fail), and streaming keeps large clips
    /// out of RAM. The timeout is inactivity-based so a long transfer is
    /// never killed while bytes are still flowing.
    private static func downloadMediaToFile(
        _ item: TideGlassesMediaItem,
        destination: URL,
        onProgress: ((Int, Int?) -> Void)? = nil
    ) async throws {
        guard let host = item.remoteURL.host else {
            throw TideGlassesMediaTransferError.invalidMediaResponse(item.filename)
        }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: 80,
            using: parameters
        )
        let queue = DispatchQueue(label: "tide.glasses.download")

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: destination)
        let path = item.remoteURL.path(percentEncoded: true)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var headerBuffer = Data()
                var headersParsed = false
                var bodyBytes = 0
                var expectedBodyBytes: Int?
                var lastActivity = Date()
                var lastLoggedMegabyte = 0
                var finished = false

                let watchdog = DispatchSource.makeTimerSource(queue: queue)

                func finish(_ result: Result<Void, Error>) {
                    guard !finished else { return }
                    finished = true
                    watchdog.cancel()
                    connection.cancel()
                    try? fileHandle.close()
                    if case .failure = result {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    continuation.resume(with: result)
                }

                func handleChunk(_ data: Data) {
                    lastActivity = Date()
                    if headersParsed {
                        writeBody(data)
                        return
                    }

                    headerBuffer.append(data)
                    guard let headerEnd = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                        if headerBuffer.count > 1 << 16 {
                            finish(.failure(TideGlassesMediaTransferError.invalidMediaResponse(item.filename)))
                        }
                        return
                    }

                    let headerText = (String(
                        data: headerBuffer[..<headerEnd.lowerBound],
                        encoding: .isoLatin1
                    ) ?? "")
                    let statusParts = headerText
                        .components(separatedBy: "\r\n").first?
                        .split(separator: " ") ?? []
                    guard statusParts.count >= 2,
                          let statusCode = Int(statusParts[1]),
                          (200...299).contains(statusCode) else {
                        finish(.failure(TideGlassesMediaTransferError.serverUnreachable(
                            "HTTP \(statusParts.count >= 2 ? String(statusParts[1]) : "?") for \(item.filename)"
                        )))
                        return
                    }
                    for line in headerText.lowercased().components(separatedBy: "\r\n") {
                        guard line.hasPrefix("content-length:") else { continue }
                        let value = line.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)
                        expectedBodyBytes = Int(value)
                    }
                    TideDiagnostics.log(
                        "download \(item.filename): headers OK, expecting \(expectedBodyBytes.map(String.init) ?? "unknown") bytes"
                    )

                    headersParsed = true
                    let body = Data(headerBuffer[headerEnd.upperBound...])
                    headerBuffer = Data()
                    if !body.isEmpty {
                        writeBody(body)
                    }
                }

                func writeBody(_ data: Data) {
                    do {
                        try fileHandle.write(contentsOf: data)
                    } catch {
                        finish(.failure(error))
                        return
                    }
                    bodyBytes += data.count
                    onProgress?(bodyBytes, expectedBodyBytes)
                    let megabytes = bodyBytes / (1 << 20)
                    if megabytes > lastLoggedMegabyte {
                        lastLoggedMegabyte = megabytes
                        TideDiagnostics.log("download \(item.filename): \(megabytes) MB…")
                    }
                    if let expectedBodyBytes, bodyBytes >= expectedBodyBytes {
                        finish(.success(()))
                    }
                }

                func receiveNext() {
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: 1 << 16
                    ) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            handleChunk(data)
                        }
                        if finished { return }
                        if isComplete {
                            if headersParsed,
                               expectedBodyBytes.map({ bodyBytes >= $0 }) ?? (bodyBytes > 0) {
                                finish(.success(()))
                            } else {
                                finish(.failure(TideGlassesMediaTransferError.invalidMediaResponse(item.filename)))
                            }
                            return
                        }
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        receiveNext()
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = "GET \(path) HTTP/1.1\r\n"
                            + "Host: \(host)\r\n"
                            + "Accept: */*\r\n"
                            + "Connection: close\r\n\r\n"
                        connection.send(
                            content: Data(request.utf8),
                            completion: .contentProcessed { error in
                                if let error {
                                    finish(.failure(error))
                                }
                            }
                        )
                        receiveNext()
                    case .failed(let error):
                        finish(.failure(error))
                    case .waiting(let error):
                        TideDiagnostics.log("download \(item.filename) waiting: \(error)")
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                // No data for 20 s means the session died; a hard overall cap
                // is deliberately absent so long videos can finish.
                watchdog.schedule(deadline: .now() + 5, repeating: 5)
                watchdog.setEventHandler {
                    if Date().timeIntervalSince(lastActivity) > 20 {
                        TideDiagnostics.log("download \(item.filename): stalled 20 s, aborting")
                        finish(.failure(NWError.posix(.ETIMEDOUT)))
                    }
                }
                watchdog.resume()
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Full-quality media fetch for grid previews; same Wi-Fi-bound raw
    /// socket path as imports, since URLSession (and therefore AsyncImage)
    /// misbehaves on the internet-less glasses hotspot.
    static func fetchPreviewData(for item: TideGlassesMediaItem) async throws -> Data {
        try await downloadMedia(item)
    }

    // MARK: - Raw Wi-Fi-bound HTTP
    //
    // The glasses hotspot has no internet, so iOS flags it "no connectivity".
    // URLSession can then fast-fail requests as "offline" or prefer cellular,
    // which made the gallery unreachable even while the phone was verifiably
    // associated. A raw TCP connection pinned to the Wi-Fi interface has
    // neither behavior, and its errors say what actually went wrong.

    private static func rawHTTPGet(
        ip: String,
        path: String,
        timeoutSeconds: Double
    ) async throws -> Data {
        let raw = try await rawHTTPExchange(
            ip: ip,
            path: path,
            timeoutSeconds: timeoutSeconds
        )
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw TideGlassesMediaTransferError.serverUnreachable(
                "malformed reply from \(ip)"
            )
        }
        let headerText = String(
            data: raw[..<headerEnd.lowerBound],
            encoding: .isoLatin1
        ) ?? ""
        let statusParts = headerText
            .components(separatedBy: "\r\n").first?
            .split(separator: " ") ?? []
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]),
              (200...299).contains(statusCode) else {
            throw TideGlassesMediaTransferError.serverUnreachable(
                "HTTP \(statusParts.count >= 2 ? String(statusParts[1]) : "?") from \(ip)\(path)"
            )
        }
        return Data(raw[headerEnd.upperBound...])
    }

    private static func rawHTTPExchange(
        ip: String,
        path: String,
        timeoutSeconds: Double
    ) async throws -> Data {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi
        let connection = NWConnection(
            host: NWEndpoint.Host(ip),
            port: 80,
            using: parameters
        )
        let queue = DispatchQueue(label: "tide.glasses.http.\(ip)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var buffer = Data()
                var expectedTotalLength: Int?
                var finished = false

                func finish(_ result: Result<Data, Error>) {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(with: result)
                }

                // Embedded servers send Content-Length; use it to complete
                // without depending on the server honoring Connection: close.
                func responseIsComplete() -> Bool {
                    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        return false
                    }
                    if expectedTotalLength == nil {
                        let headerText = (String(
                            data: buffer[..<headerEnd.lowerBound],
                            encoding: .isoLatin1
                        ) ?? "").lowercased()
                        for line in headerText.components(separatedBy: "\r\n") {
                            guard line.hasPrefix("content-length:") else { continue }
                            let value = line.dropFirst("content-length:".count)
                                .trimmingCharacters(in: .whitespaces)
                            if let length = Int(value) {
                                expectedTotalLength = headerEnd.upperBound + length
                            }
                        }
                    }
                    guard let expectedTotalLength else { return false }
                    return buffer.count >= expectedTotalLength
                }

                func receiveNext() {
                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: 1 << 16
                    ) { data, _, isComplete, error in
                        if let data, !data.isEmpty {
                            buffer.append(data)
                        }
                        if responseIsComplete() || isComplete {
                            finish(.success(buffer))
                            return
                        }
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        receiveNext()
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let request = "GET \(path) HTTP/1.1\r\n"
                            + "Host: \(ip)\r\n"
                            + "Accept: */*\r\n"
                            + "Connection: close\r\n\r\n"
                        connection.send(
                            content: Data(request.utf8),
                            completion: .contentProcessed { error in
                                if let error {
                                    finish(.failure(error))
                                }
                            }
                        )
                        receiveNext()
                    case .failed(let error):
                        finish(.failure(error))
                    case .waiting(let error):
                        // No route yet — the deadline decides; record why.
                        TideDiagnostics.log("probe \(ip) waiting: \(error)")
                    case .cancelled:
                        finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    finish(.failure(NWError.posix(.ETIMEDOUT)))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static func parseManifest(_ manifest: String) -> [String] {
        manifest
            .components(separatedBy: .newlines)
            .compactMap { rawLine -> String? in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                let filename: String
                if let absolute = URL(string: line), absolute.scheme != nil {
                    filename = absolute.lastPathComponent
                } else {
                    filename = URL(fileURLWithPath: line).lastPathComponent
                }

                guard !filename.isEmpty,
                      !filename.contains(".."),
                      kind(for: filename) != .unknown else { return nil }
                return filename
            }
    }

    private static func isPlausibleManifest(_ manifest: String) -> Bool {
        let trimmed = manifest.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        guard !lower.contains("<html"), !lower.contains("<!doctype") else { return false }
        return !parseManifest(manifest).isEmpty
    }

    private static func mediaURL(ip: String, filename: String) -> URL? {
        guard var components = URLComponents(string: "http://\(ip)/files/") else { return nil }
        components.path += filename
        return components.url
    }

    private static func kind(for filename: String) -> TideGlassesMediaItem.Kind {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": .photo
        case "mp4", "mov", "m4v": .video
        case "opus", "wav", "m4a", "aac": .audio
        default: .unknown
        }
    }

    private static func applyHotspotConfiguration(
        _ credentials: TideGlassesWiFiCredentials,
        removingExisting: Bool = true
    ) async throws {
        // The hotspot helper's XPC service can die mid-apply and never call
        // back (seen live as "XPC connection invalidated"), which froze the
        // entire flow with every button disabled. Never wait on it unboundedly.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await applyHotspotConfigurationOnce(
                    credentials,
                    removingExisting: removingExisting
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                TideDiagnostics.log("Wi-Fi apply TIMED OUT after 20 s — hotspot helper never answered")
                throw TideGlassesMediaTransferError.automaticJoinUnavailable
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private static func applyHotspotConfigurationOnce(
        _ credentials: TideGlassesWiFiCredentials,
        removingExisting: Bool
    ) async throws {
        #if os(iOS)
        let configuration = NEHotspotConfiguration(
            ssid: credentials.ssid,
            passphrase: credentials.password,
            isWEP: false
        )
        // Match WiFiTransferManager.m from the full HeyCyan iOS transfer path.
        // A short-lived persistent profile lets iOS continue association after
        // the system Join sheet closes, which is important in Wi-Fi-dense areas.
        configuration.joinOnce = false
        if #available(iOS 13.0, *) {
            configuration.lifeTimeInDays = 1
        }

        // The SDK clears a failed profile immediately before applying the fresh
        // one. removeConfiguration has no completion callback by design. The
        // mid-association re-apply skips removal so iOS keeps retrying the
        // profile it already has instead of starting over.
        if removingExisting {
            NEHotspotConfigurationManager.shared.removeConfiguration(
                forSSID: credentials.ssid
            )
        }

        TideDiagnostics.log(
            "Wi-Fi apply: SSID=\(credentials.ssid) "
            + "joinOnce=false lifetime=1 removeExisting=\(removingExisting)"
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    let nsError = error as NSError
                    TideDiagnostics.log(
                        "Wi-Fi apply failed: domain=\(nsError.domain) "
                        + "code=\(nsError.code) description=\(nsError.localizedDescription)"
                    )
                    if nsError.domain == NEHotspotConfigurationErrorDomain,
                       nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        TideDiagnostics.log("Wi-Fi apply: already associated")
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    TideDiagnostics.log("Wi-Fi apply accepted by iOS")
                    continuation.resume()
                }
            }
        }
        #else
        throw TideGlassesMediaTransferError.automaticJoinUnavailable
        #endif
    }

    private static func saveToPhotos(
        fileURL: URL,
        item: TideGlassesMediaItem
    ) async throws {
        #if canImport(Photos)
        guard item.canImportToPhotos else {
            throw TideGlassesMediaTransferError.unsupportedMedia
        }

        let authorization = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard authorization == .authorized || authorization == .limited else {
            throw TideGlassesMediaTransferError.photoPermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.filename
                options.shouldMoveFile = false
                // Videos must be added from a file URL — byte-based video
                // saves are rejected by Photos.
                request.addResource(
                    with: item.kind == .video ? .video : .photo,
                    fileURL: fileURL,
                    options: options
                )
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TideGlassesMediaTransferError.invalidMediaResponse(item.filename))
                }
            }
        }
        #else
        throw TideGlassesMediaTransferError.photoPermissionDenied
        #endif
    }
}
