//
//  TideGlassesPhotoCapture.swift
//  Tide Glasses
//
//  Pulls a photo off the glasses over Bluetooth, so the assistant can see what
//  the wearer is looking at.
//
//  Protocol proven on the Mac rig before any of this was written (see
//  AGENTS.md). The image is PULLED, never pushed — taking the photo returns
//  only an acknowledgement:
//
//      TX  0x41 [02 01 06 02 02 02]            take a fresh photo
//      RX  0x41 [02 01 06 ff ff]               ack
//      RX  0x73 [02 00 NN 01 00]               ready, NN chunks
//      TX  0xFD [02 idxLo idxHi]               request chunk idx
//      RX  0xFD [01 cntLo cntHi idxLo idxHi] + body
//
//  Bodies are 1013 bytes except the last, which is short. Concatenated in
//  index order they form a 512x384 JPEG of about 22 KB.
//
//  The index in a request is a little-endian 16-bit value at byte OFFSET 1 —
//  byte 0 is a type prefix the firmware ignores. This matters: putting the
//  index at offset 0 silently returns chunk 0 every time.
//

import Foundation
import UIKit

enum TideCaptureError: LocalizedError {
    case notConnected
    case noResponse
    case incomplete(received: Int, expected: Int)
    case notAnImage

    var errorDescription: String? {
        switch self {
        case .notConnected: "The glasses are not connected."
        case .noResponse: "The glasses did not respond to the camera request."
        case .incomplete(let received, let expected):
            "Only \(received) of \(expected) image pieces arrived."
        case .notAnImage: "The glasses sent something that was not a photo."
        }
    }
}

@MainActor
final class TideGlassesPhotoCapture {
    private unowned let bluetooth: TideGlassesBluetoothManager

    private var chunks: [Int: Data] = [:]
    private var chunkCount: Int?
    private var waitingFor: Int?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Measured at 60–90 ms per chunk; this is generous.
    private static let chunkTimeout: Duration = .milliseconds(1500)
    private static let readyTimeout: Duration = .seconds(6)
    private static let retriesPerChunk = 3
    private static let headerLength = 5
    /// A stuck counter must not spin forever.
    private static let maximumChunks = 200

    init(bluetooth: TideGlassesBluetoothManager) {
        self.bluetooth = bluetooth
    }

    // MARK: - Capture

    /// Takes a photo and returns it as JPEG data.
    func capture() async throws -> Data {
        guard bluetooth.isConnected else { throw TideCaptureError.notConnected }

        chunks = [:]
        chunkCount = nil

        guard bluetooth.sendVisionCommand(
            command: Command.control,
            payload: Data([0x02, 0x01, Mode.aiPhoto, 0x02, 0x02, 0x02])
        ) else { throw TideCaptureError.notConnected }

        // The 0x73 ready report gives a chunk count, but the 0xFD header has
        // disagreed with it — so treat 0x73 only as "the photo exists now" and
        // take the real count from the first chunk's header.
        await waitForReady()

        var index = 0
        while index < (chunkCount ?? Self.maximumChunks), index < Self.maximumChunks {
            var arrived = false
            for _ in 0..<Self.retriesPerChunk {
                if await request(chunk: index) {
                    arrived = true
                    break
                }
            }
            guard arrived else { break }
            index += 1
        }

        let expected = chunkCount ?? chunks.count
        guard !chunks.isEmpty else { throw TideCaptureError.noResponse }
        guard chunks.count == expected else {
            throw TideCaptureError.incomplete(received: chunks.count, expected: expected)
        }

        let jpeg = chunks.sorted { $0.key < $1.key }.map(\.value).reduce(Data(), +)
        guard jpeg.count > 4, jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]) else {
            throw TideCaptureError.notAnImage
        }
        return jpeg
    }

    /// Convenience for the voice path, which wants a UIImage.
    func captureImage() async throws -> UIImage {
        let data = try await capture()
        guard let image = UIImage(data: data) else { throw TideCaptureError.notAnImage }
        return image
    }

    // MARK: - Chunk pull

    private func request(chunk index: Int) async -> Bool {
        if chunks[index] != nil { return true }

        let payload = Data([0x02, UInt8(index & 0xFF), UInt8((index >> 8) & 0xFF)])
        guard bluetooth.sendVisionCommand(command: Command.thumbnail, payload: payload) else {
            return false
        }
        return await wait(for: index, timeout: Self.chunkTimeout)
    }

    private func waitForReady() async {
        _ = await wait(for: nil, timeout: Self.readyTimeout)
    }

    /// Suspends until the given chunk arrives (or, with nil, until the ready
    /// report does). Returns false on timeout.
    private func wait(for index: Int?, timeout: Duration) async -> Bool {
        if let index, chunks[index] != nil { return true }

        return await withCheckedContinuation { continuation in
            waitingFor = index
            waiter = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishWait(false)
            }
        }
    }

    private func finishWait(_ success: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        waitingFor = nil
        guard let continuation = waiter else { return }
        waiter = nil
        continuation.resume(returning: success)
    }

    // MARK: - Packet tap

    /// Fed from the BLE observer. Ignores everything that is not part of a
    /// capture in progress.
    func handle(command: UInt8, payload: Data) {
        switch command {
        case Command.report:
            // [02, 00, count, ...] — the photo is ready to be read.
            guard payload.count >= 3, payload[0] == 0x02, waitingFor == nil else { return }
            finishWait(true)

        case Command.thumbnail:
            guard payload.count > Self.headerLength else { return }
            let count = Int(payload[1]) | (Int(payload[2]) << 8)
            let index = Int(payload[3]) | (Int(payload[4]) << 8)
            guard count > 0, count <= Self.maximumChunks else { return }

            chunkCount = count
            chunks[index] = payload.dropFirst(Self.headerLength)

            if waitingFor == index { finishWait(true) }

        default:
            break
        }
    }

    private enum Command {
        static let control: UInt8 = 0x41
        static let report: UInt8 = 0x73
        static let thumbnail: UInt8 = 0xFD
    }

    private enum Mode {
        static let aiPhoto: UInt8 = 0x06
    }
}
