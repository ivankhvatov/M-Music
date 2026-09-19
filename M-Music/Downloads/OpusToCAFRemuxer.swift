import AudioToolbox
import Foundation

/// Remuxes an Opus-in-Ogg file into a `.caf` container — a pure byte-for-byte repackaging of the
/// already-encoded Opus packets, never a decode/re-encode. Uses the low-level `AudioFile`
/// Services (`AudioFileCreateWithURL`/`AudioFileWritePackets`), not `ExtAudioFile`, since
/// `ExtAudioFile`'s client format must be linear PCM whenever the file format is compressed —
/// that would force an unwanted decode-then-encode round trip.
///
/// The CAF magic-cookie format for Opus isn't documented by Apple anywhere (even FFmpeg's
/// maintainers state in `cafenc.c`/`cafdec.c` that they never solved it and refuse to write it).
/// It was reverse-engineered empirically by converting known test files with `afconvert` (Apple's
/// own CLI) and parsing the resulting CAF chunks directly: the cookie is a fixed 28-byte template
/// — 7 big-endian `Int32`s, `(2048, 48000, framesPerPacket, -1000, channelCount, 0, 0)` — where
/// only `framesPerPacket` and `channelCount` vary between files.
enum OpusToCAFRemuxer {
    enum RemuxError: LocalizedError {
        case oggParseFailed(Error)
        case noAudioPackets
        case implausibleGaplessMath(remainderFrames: Int64)
        case createFileFailed(OSStatus)
        case setMagicCookieFailed(OSStatus)
        case writePacketsFailed(OSStatus)
        case setPacketTableInfoFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .oggParseFailed(let error): return "Could not parse Ogg Opus source: \(error.localizedDescription)"
            case .noAudioPackets: return "Ogg Opus source has no audio packets"
            case .implausibleGaplessMath(let remainder):
                return "Computed remainder frames (\(remainder)) outside a plausible range — frame-size assumption may not hold for this source"
            case .createFileFailed(let status): return "Could not create CAF destination file (\(status))"
            case .setMagicCookieFailed(let status): return "Could not set Opus magic cookie (\(status))"
            case .writePacketsFailed(let status): return "Could not write Opus packets (\(status))"
            case .setPacketTableInfoFailed(let status): return "Could not set gapless packet table info (\(status))"
            }
        }
    }

    /// The Opus frame duration virtually all music encoders use: 20ms @ 48kHz = 960
    /// samples/channel. Used for the CAF `desc`/magic-cookie chunks' frames-per-packet and as
    /// every packet's nominal frame count for gapless bookkeeping. `implausibleGaplessMath`
    /// catches it defensively if a source doesn't actually use this duration, rather than writing
    /// wrong trim metadata.
    private static let standardFrameSize: Int64 = 960

    /// Remuxes the Opus audio packets inside the Ogg container at `sourceURL` into a `.caf` file
    /// at a new temporary URL the caller owns (must move or delete it). Throws
    /// `.oggParseFailed(OggPageParser.ParseError.unsupportedChannelMapping)` for anything but
    /// Opus channel-mapping family 0 (mono/stereo) — callers should catch this and fall back to
    /// keeping the original download.
    static func remux(sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try remuxSync(sourceURL: sourceURL)
        }.value
    }

    private static func remuxSync(sourceURL: URL) throws -> URL {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let parsed: OggPageParser.ParsedStream
        do {
            parsed = try OggPageParser.parse(data: data)
        } catch {
            throw RemuxError.oggParseFailed(error)
        }
        guard !parsed.packets.isEmpty else { throw RemuxError.noAudioPackets }

        let channelCount = Int32(parsed.head.channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(standardFrameSize),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmusic_opus_\(UUID().uuidString).caf")
        var audioFile: AudioFileID?
        var status = AudioFileCreateWithURL(
            destURL as CFURL, kAudioFileCAFType, &asbd, .eraseFile, &audioFile
        )
        guard status == noErr, let audioFile else { throw RemuxError.createFileFailed(status) }
        var didSucceed = false
        defer {
            AudioFileClose(audioFile)
            if !didSucceed { try? FileManager.default.removeItem(at: destURL) }
        }

        let cookie: [Int32] = [2048, 48000, Int32(standardFrameSize), -1000, channelCount, 0, 0]
            .map { $0.bigEndian }
        status = cookie.withUnsafeBufferPointer { buffer in
            AudioFileSetProperty(
                audioFile, kAudioFilePropertyMagicCookieData,
                UInt32(buffer.count * MemoryLayout<Int32>.size), buffer.baseAddress!
            )
        }
        guard status == noErr else { throw RemuxError.setMagicCookieFailed(status) }

        var payload = Data()
        payload.reserveCapacity(parsed.packets.reduce(0) { $0 + $1.data.count })
        var descriptions: [AudioStreamPacketDescription] = []
        descriptions.reserveCapacity(parsed.packets.count)
        for packet in parsed.packets {
            descriptions.append(
                AudioStreamPacketDescription(
                    mStartOffset: Int64(payload.count),
                    mVariableFramesInPacket: UInt32(standardFrameSize),
                    mDataByteSize: UInt32(packet.data.count)
                )
            )
            payload.append(packet.data)
        }

        var ioNumPackets = UInt32(descriptions.count)
        status = payload.withUnsafeBytes { rawBuffer -> OSStatus in
            descriptions.withUnsafeBufferPointer { descBuffer in
                AudioFileWritePackets(
                    audioFile, false, UInt32(payload.count), descBuffer.baseAddress,
                    0, &ioNumPackets, rawBuffer.baseAddress!
                )
            }
        }
        guard status == noErr else { throw RemuxError.writePacketsFailed(status) }

        let preSkip = Int64(parsed.head.preSkip)
        let nominalTotalFrames = standardFrameSize * Int64(parsed.packets.count)
        let realTotalFrames = max(0, parsed.finalGranulePosition - preSkip)
        let remainderFrames = nominalTotalFrames - preSkip - realTotalFrames
        guard (0..<standardFrameSize).contains(remainderFrames) else {
            throw RemuxError.implausibleGaplessMath(remainderFrames: remainderFrames)
        }
        var packetTableInfo = AudioFilePacketTableInfo(
            mNumberValidFrames: realTotalFrames,
            mPrimingFrames: Int32(preSkip),
            mRemainderFrames: Int32(remainderFrames)
        )
        status = AudioFileSetProperty(
            audioFile, kAudioFilePropertyPacketTableInfo,
            UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &packetTableInfo
        )
        guard status == noErr else { throw RemuxError.setPacketTableInfoFailed(status) }

        didSucceed = true
        return destURL
    }
}
