import Foundation

/// Distinguishes a transient network hiccup (worth a quiet retry) from a
/// definitive failure (bad auth, unsupported format, malformed data, etc.)
/// that a retry can't fix and should be reported immediately.
///
/// Ported from Shelv's `ShelvCore/Services/RemoteStreamFailureRetryPolicy.swift`.
enum RemoteStreamFailureErrorClassifier {
    static func isTransientNetworkError(_ error: Error?) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return transientCodes.contains(urlError.code)
    }

    private static let transientCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .timedOut,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
    ]
}

/// Decides whether a failed remote stream should be retried quietly instead
/// of surfacing an error right away. Bounded to a small number of attempts so
/// a persistent failure still falls through.
struct RemoteStreamFailureRetryPolicy {
    private var attemptCount = 0

    static let maxAttempts = 2

    /// Returns whether the caller should retry, based on the error type and
    /// how many retries have already been attempted for the current playback
    /// attempt. Any non-transient error resets the attempt count, so a later,
    /// unrelated transient failure for the same song starts a fresh budget.
    mutating func shouldRetry(for error: Error?) -> Bool {
        guard RemoteStreamFailureErrorClassifier.isTransientNetworkError(error) else {
            attemptCount = 0
            return false
        }
        guard attemptCount < Self.maxAttempts else { return false }
        attemptCount += 1
        return true
    }

    mutating func reset() {
        attemptCount = 0
    }
}
