import Foundation

/// Ported from Shelv's `ShelvCore/Utilities/PathSafe.swift`.
extension String {
    /// Makes a server-supplied identifier safe to use as a single path component.
    ///
    /// Subsonic/Navidrome ids are normally alphanumeric and pass through unchanged, but a
    /// malicious or compromised server could return an id containing `/`, `\`, or leading dots
    /// and use that to escape the destination folder via `appendingPathComponent` (path
    /// traversal). With no separators left, no directory change is possible.
    nonisolated var pathSafeComponent: String {
        var s = self
        for separator in ["/", "\\", "\0", ":"] {
            s = s.replacingOccurrences(of: separator, with: "_")
        }
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "_" : s
    }

    /// Makes a server-supplied file extension safe to use as part of a filename.
    nonisolated func pathSafeFileExtension(default fallback: String = "mp3") -> String {
        var s = trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.pathSafeComponent
        if s == "_" {
            return fallback.pathSafeComponent
        }
        return s
    }
}
