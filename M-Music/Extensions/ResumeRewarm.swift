import SwiftUI

/// Where in a list or carousel the user last was — the index of the row or card that most recently
/// appeared (per list, for a screen with several). Not observable on purpose: writing it must not
/// re-render anything. Read when the app resumes, to warm the images around that spot again.
final class LastSeenIndex {
    var index = 0
    var byKey: [String: Int] = [:]

    /// How many rows a list scrolls before it warms ahead again. Each pass covers
    /// `ImageWarmer.scrollAheadCount` rows around where it is, half on each side, so one every few
    /// rows stays well ahead of any scroll — one for every row that appeared did the same work
    /// many times over on the main thread, in the middle of the scroll.
    static let warmStride = 8
    private var warmed: (index: Int, count: Int)?

    /// Whether a list of `count` rows that has reached `index` should warm ahead from there.
    func shouldWarm(at index: Int, of count: Int) -> Bool {
        if let warmed, warmed.count == count, abs(warmed.index - index) < Self.warmStride { return false }
        warmed = (index, count)
        return true
    }

    /// The rows changed: the next one to appear warms ahead, wherever it is.
    func forgetWarmed() {
        warmed = nil
    }
}

extension View {
    /// Runs `action` each time the app becomes active again. While the app was away iOS may have
    /// emptied the in-memory image cache — including the rows and cards a list was scrolled away
    /// from, which then show placeholders when it's scrolled back — so a screen with a look-ahead
    /// uses this to warm the images around where it was left (nearest first, both directions).
    func onAppResume(perform action: @escaping () -> Void) -> some View {
        modifier(AppResume(action: action))
    }
}

private struct AppResume: ViewModifier {
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            if phase == .active { action() }
        }
    }
}
