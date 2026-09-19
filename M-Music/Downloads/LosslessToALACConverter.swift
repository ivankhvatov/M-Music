import AudioToolbox
import Foundation

/// Converts a local FLAC/WAV/AIFF file to Apple Lossless (ALAC) in an `.m4a` container, using
/// `ExtAudioFile` (AudioToolbox) exclusively — never `AVAssetExportSession`/`AVAudioConverter`.
/// ALAC needs no gapless bookkeeping: unlike AAC it has no fixed encoder delay and natively
/// supports a variable-length final packet, so there's no silence padding to trim.
enum LosslessToALACConverter {
    enum ConversionError: LocalizedError {
        case openSourceFailed(OSStatus)
        case readSourceFormatFailed(OSStatus)
        case createDestinationFailed(OSStatus)
        case setClientFormatFailed(OSStatus)
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
        case frameCountMismatch(read: Int64, written: Int64)

        var errorDescription: String? {
            switch self {
            case .openSourceFailed(let status): return "Could not open source file (\(status))"
            case .readSourceFormatFailed(let status): return "Could not read source format (\(status))"
            case .createDestinationFailed(let status): return "Could not create ALAC destination file (\(status))"
            case .setClientFormatFailed(let status): return "Could not set PCM client format (\(status))"
            case .readFailed(let status): return "Could not read source audio (\(status))"
            case .writeFailed(let status): return "Could not write ALAC audio (\(status))"
            case .frameCountMismatch(let read, let written):
                return "Frame count mismatch after conversion: read \(read), wrote \(written)"
            }
        }
    }

    /// Converts `sourceURL` to ALAC, returning a new temporary file URL the caller owns (must
    /// move or delete it). On any thrown error, the destination temp file (if created) is removed
    /// first.
    static func convert(sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try convertSync(sourceURL: sourceURL)
        }.value
    }

    private static func convertSync(sourceURL: URL) throws -> URL {
        var sourceFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(sourceURL as CFURL, &sourceFile)
        guard status == noErr, let sourceFile else { throw ConversionError.openSourceFailed(status) }
        defer { ExtAudioFileDispose(sourceFile) }

        var sourceFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            sourceFile, kExtAudioFileProperty_FileDataFormat, &propSize, &sourceFormat
        )
        guard status == noErr else { throw ConversionError.readSourceFormatFailed(status) }

        let bitsPerChannel: UInt32 = sourceFormat.mBitsPerChannel > 0 ? sourceFormat.mBitsPerChannel : 16
        let alacFlag: UInt32
        switch bitsPerChannel {
        case ...16: alacFlag = UInt32(kAppleLosslessFormatFlag_16BitSourceData)
        case 17...20: alacFlag = UInt32(kAppleLosslessFormatFlag_20BitSourceData)
        case 21...24: alacFlag = UInt32(kAppleLosslessFormatFlag_24BitSourceData)
        default: alacFlag = UInt32(kAppleLosslessFormatFlag_32BitSourceData)
        }
        let clientBitsPerChannel: UInt32 = bitsPerChannel <= 16 ? 16 : 32
        let sampleRate = sourceFormat.mSampleRate
        let channels = sourceFormat.mChannelsPerFrame

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: (clientBitsPerChannel / 8) * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: (clientBitsPerChannel / 8) * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: clientBitsPerChannel,
            mReserved: 0
        )
        status = ExtAudioFileSetProperty(
            sourceFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
        )
        guard status == noErr else { throw ConversionError.setClientFormatFailed(status) }

        var destFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: alacFlag,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmusic_alac_\(UUID().uuidString).m4a")
        var destFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            destURL as CFURL, kAudioFileM4AType, &destFormat, nil, AudioFileFlags.eraseFile.rawValue, &destFile
        )
        guard status == noErr, let destFile else { throw ConversionError.createDestinationFailed(status) }
        var didSucceed = false
        defer {
            ExtAudioFileDispose(destFile)
            if !didSucceed { try? FileManager.default.removeItem(at: destURL) }
        }

        status = ExtAudioFileSetProperty(
            destFile, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat
        )
        guard status == noErr else { throw ConversionError.setClientFormatFailed(status) }

        let bufferFrameCapacity: UInt32 = 32768
        let bytesPerFrame = clientFormat.mBytesPerFrame
        var buffer = [UInt8](repeating: 0, count: Int(bufferFrameCapacity * bytesPerFrame))
        var totalFramesRead: Int64 = 0
        var totalFramesWritten: Int64 = 0

        while true {
            var frameCount = bufferFrameCapacity
            let bytesWritten = try buffer.withUnsafeMutableBytes { rawBuffer -> UInt32 in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(rawBuffer.count),
                        mData: rawBuffer.baseAddress
                    )
                )
                let readStatus = ExtAudioFileRead(sourceFile, &frameCount, &bufferList)
                guard readStatus == noErr else { throw ConversionError.readFailed(readStatus) }
                return bufferList.mBuffers.mDataByteSize
            }
            if frameCount == 0 { break }
            totalFramesRead += Int64(frameCount)

            try buffer.withUnsafeMutableBytes { rawBuffer in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: bytesWritten, mData: rawBuffer.baseAddress)
                )
                let writeStatus = ExtAudioFileWrite(destFile, frameCount, &bufferList)
                guard writeStatus == noErr else { throw ConversionError.writeFailed(writeStatus) }
            }
            totalFramesWritten += Int64(frameCount)
        }

        guard totalFramesRead == totalFramesWritten else {
            throw ConversionError.frameCountMismatch(read: totalFramesRead, written: totalFramesWritten)
        }
        didSucceed = true
        return destURL
    }
}
