import Foundation

/// The on-device container conversions shared by everything that ends up holding a finished audio
/// file — real downloads (`DownloadService`, gated by `DownloadConversionSettings`) and the
/// gapless cache (`GaplessCacheService`/`EphemeralGaplessCacheService`, gated by
/// `GaplessCacheSettings`). Callers pass their own switches in; this only does the work.
enum AudioContainerConversion {
    struct Converted {
        let url: URL
        let ext: String
        let byteSize: Int64
        let contentType: String?
    }

    private static let losslessExtensions: Set<String> = ["flac", "wav", "aiff"]

    /// Converts `originalURL` (whose extension is `ext`) if a switch that applies to it is on:
    /// lossless (FLAC/WAV/AIFF) to ALAC in `.m4a`, or Opus remuxed into `.caf` with no re-encode.
    /// On success the converted file sits next to `originalURL` with the same base name and the
    /// new extension, and `originalURL` has been deleted. On failure — a corrupt/unsupported
    /// source, a multichannel Opus file, disk pressure, ... — this asserts (visible in debug
    /// builds, a no-op in release) and returns `nil`, leaving `originalURL` untouched: a
    /// conversion bug must never cost the caller a playable file.
    static func convertIfNeeded(
        originalURL: URL, ext: String, losslessToALAC: Bool, opusToCAF: Bool
    ) async -> Converted? {
        do {
            if losslessToALAC, losslessExtensions.contains(ext) {
                let convertedURL = try await LosslessToALACConverter.convert(sourceURL: originalURL)
                return try finalize(convertedURL: convertedURL, originalURL: originalURL, ext: "m4a", contentType: "audio/mp4")
            }
            if opusToCAF, ext == "opus" {
                let convertedURL = try await OpusToCAFRemuxer.remux(sourceURL: originalURL)
                return try finalize(convertedURL: convertedURL, originalURL: originalURL, ext: "caf", contentType: nil)
            }
            return nil
        } catch {
            assertionFailure("Container conversion failed for \(originalURL.lastPathComponent), keeping original file: \(error)")
            return nil
        }
    }

    /// Moves a converter's temp-directory output next to the original, only then deletes the
    /// now-superseded original — `originalURL` is never touched until the converted file is
    /// confirmed in place, so a thrown error still leaves a fully intact, playable original.
    private static func finalize(
        convertedURL: URL, originalURL: URL, ext: String, contentType: String?
    ) throws -> Converted {
        defer { try? FileManager.default.removeItem(at: convertedURL) }
        let destination = originalURL.deletingPathExtension().appendingPathExtension(ext)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: convertedURL, to: destination)
        try? FileManager.default.removeItem(at: originalURL)
        let byteSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Converted(url: destination, ext: ext, byteSize: byteSize, contentType: contentType)
    }
}
