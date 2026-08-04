//
//  TideOpusDecoder.swift
//  Tide Glasses
//
//  The glasses save voice recordings as a bare stream of fixed-size Opus
//  packets — no Ogg container, no WAV header, just 40-byte CBR frames back to
//  back (TOC 0x4B, one 20 ms frame each). Nothing in AVFoundation opens that
//  directly, but AudioToolbox's converter decodes the packets natively, so no
//  third-party Opus library is needed.
//

import AudioToolbox
import AVFoundation

enum TideOpusDecoder {
    static let packetSize = 40
    static let sampleRate = 16_000.0
    static let framesPerPacket: UInt32 = 320   // 20 ms at 16 kHz

    /// True when the file looks like the glasses' raw Opus recording format.
    static func looksLikeGlassesOpus(url: URL) -> Bool {
        if url.pathExtension.lowercased() == "opus" { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head.count == 2 && head[0] == 0x4B && head[1] == 0x41
    }

    /// Decodes the whole recording into a playable buffer, or nil if the file
    /// is not in this format.
    static func decode(url: URL) -> AVAudioPCMBuffer? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data: data)
    }

    /// Same decode for audio that never touched disk — the live BLE mic stream
    /// arrives as these exact 40-byte packets on command 0x59.
    static func decode(data: Data) -> AVAudioPCMBuffer? {
        guard data.count >= packetSize else { return nil }

        let packets: [[UInt8]] = stride(from: 0, to: data.count - (packetSize - 1), by: packetSize)
            .map { [UInt8](data.subdata(in: $0..<($0 + packetSize))) }
        guard !packets.isEmpty else { return nil }

        var inFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)

        var converterOpt: AudioConverterRef?
        guard AudioConverterNew(&inFormat, &outFormat, &converterOpt) == noErr,
              let converter = converterOpt else { return nil }
        defer { AudioConverterDispose(converter) }

        let feed = PacketFeed(packets: packets)
        let feedPointer = Unmanaged.passUnretained(feed).toOpaque()

        let capacity = 8192
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { scratch.deallocate() }

        var samples: [Float] = []
        samples.reserveCapacity(packets.count * Int(framesPerPacket))

        while true {
            var frames = UInt32(capacity)
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(capacity * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(scratch)
                )
            )
            let status = AudioConverterFillComplexBuffer(
                converter, inputProc, feedPointer, &frames, &list, nil
            )
            if frames == 0 { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: scratch, count: Int(frames)))
            if status != noErr { break }
        }

        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// Holds packets and a stable scratch buffer for the C callback. Handing
    /// the callback a Swift `Data` directly trips exclusivity checks.
    private final class PacketFeed {
        let packets: [[UInt8]]
        var index = 0
        var description = AudioStreamPacketDescription()
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)

        init(packets: [[UInt8]]) { self.packets = packets }
        deinit { scratch.deallocate() }
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberPackets, ioData, outDescription, userData in

        guard let userData else {
            ioNumberPackets.pointee = 0
            return noErr
        }
        let feed = Unmanaged<PacketFeed>.fromOpaque(userData).takeUnretainedValue()
        guard feed.index < feed.packets.count else {
            ioNumberPackets.pointee = 0
            return noErr
        }

        let packet = feed.packets[feed.index]
        feed.index += 1
        packet.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            feed.scratch.copyMemory(from: base, byteCount: packet.count)
        }
        feed.description = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count)
        )

        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = feed.scratch
        ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
        ioData.pointee.mBuffers.mNumberChannels = 1
        outDescription?.pointee = withUnsafeMutablePointer(to: &feed.description) { $0 }
        ioNumberPackets.pointee = 1
        return noErr
    }
}
