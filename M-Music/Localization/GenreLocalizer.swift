import Foundation
import Observation
import SwiftUI
import Translation

/// Shows a genre in the app language. A genre in the bundled `LocalizedGenres.json` is looked up
/// there; any other is translated once with the system Translation framework (through
/// `GenreTranslationHost`) and the result kept in a file, so it's never translated twice.
///
/// Only the text shown is localized — a genre name used to filter, group or query the server
/// stays the raw one.
@MainActor @Observable
final class GenreLocalizer {
    static let shared = GenreLocalizer()

    private struct Entry: Decodable {
        let id: String
        let en: String
        let de: String
        let ru: String

        func name(in language: String) -> String {
            switch language {
            case "de": de
            case "ru": ru
            default: en
            }
        }
    }

    /// The languages the app is localized in.
    nonisolated static let supportedLanguages = ["en", "de", "ru"]

    /// The app language, as one of `supportedLanguages`.
    nonisolated static var appLanguage: String {
        let code = Bundle.main.preferredLocalizations.first?.prefix(2).lowercased() ?? "en"
        return supportedLanguages.contains(code) ? code : "en"
    }

    /// Bumped whenever translations arrive, so views that call `localized(_:)` in their `body`
    /// show them.
    private(set) var revision = 0
    /// Bumped when a genre is queued for translation; what `GenreTranslationHost` watches.
    private(set) var pendingToken = 0

    let language: String
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private let entries: [String: Entry]
    /// language → normalized genre → translation.
    @ObservationIgnored private var cache: [String: [String: String]]
    /// Normalized genre → the genre as first seen, waiting for a translation.
    @ObservationIgnored private var pending: [String: String] = [:]
    /// Genres whose translation failed this launch, so they aren't asked for again in a loop.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var tokenBumpScheduled = false

    init(
        language: String = GenreLocalizer.appLanguage,
        isEnabled: @escaping () -> Bool = { GenreTranslationSettings.isEnabled },
        cacheURL: URL? = GenreLocalizer.defaultCacheURL,
        entriesURL: URL? = Bundle.main.url(forResource: "LocalizedGenres", withExtension: "json")
    ) {
        self.language = language
        self.isEnabled = isEnabled
        self.cacheURL = cacheURL

        var entries: [String: Entry] = [:]
        if let entriesURL, let data = try? Data(contentsOf: entriesURL),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in list {
                for key in [entry.id, entry.en, entry.de, entry.ru] {
                    entries[Self.normalize(key)] = entry
                }
            }
        }
        self.entries = entries

        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            cache = stored
        } else {
            cache = [:]
        }
    }

    nonisolated private static var defaultCacheURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GenreTranslations.json")
    }

    /// Lowercased, accents folded, everything but letters and digits dropped: "Hip-Hop", "hip hop"
    /// and "Hip Hop" are the same genre.
    nonisolated static func normalize(_ genre: String) -> String {
        let folded = genre.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: Lookup

    /// The genre to show: the raw one while the switch is off or while a translation is pending.
    /// A tag with several genres ("R&B/Soul", "Rock; Pop") is localized part by part.
    func localized(_ genre: String) -> String {
        _ = revision
        guard isEnabled() else { return genre }
        var result = ""
        var part = ""
        for character in genre {
            if character == ";" || character == "/" {
                result += localizedPart(part) + String(character)
                part = ""
            } else {
                part.append(character)
            }
        }
        return result + localizedPart(part)
    }

    private func localizedPart(_ part: String) -> String {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.normalize(trimmed)
        guard !key.isEmpty else { return part }
        let leading = part.prefix { $0.isWhitespace || $0.isNewline }
        let trailing = part.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed()
        func padded(_ text: String) -> String { String(leading) + text + String(trailing) }

        if let entry = entries[key] { return padded(entry.name(in: language)) }
        if language == "en" { return part }
        if let cached = cache[language]?[key] { return padded(cached) }
        // Already written in the target language's script, nothing to translate.
        if language == "ru", trimmed.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
            return part
        }
        enqueue(trimmed, key: key)
        return part
    }

    private func enqueue(_ genre: String, key: String) {
        guard pending[key] == nil, !failed.contains(key) else { return }
        pending[key] = genre
        // Not bumped here: this runs inside a view's `body`.
        guard !tokenBumpScheduled else { return }
        tokenBumpScheduled = true
        Task { @MainActor in
            tokenBumpScheduled = false
            pendingToken += 1
        }
    }

    // MARK: Translation

    var hasPending: Bool { !pending.isEmpty }

    /// Hands out the queued genres (normalized key → genre as first seen) for translation.
    func takePending() -> [String: String] {
        defer { pending = [:] }
        return pending
    }

    /// Stores a batch's translations, and the genres that couldn't be translated.
    func finish(translations: [String: String], failed failedKeys: Set<String>) {
        failed.formUnion(failedKeys)
        if !translations.isEmpty {
            cache[language, default: [:]].merge(translations) { _, new in new }
            save()
        }
        revision += 1
    }

    private func save() {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// Runs the Translation framework for `GenreLocalizer`. `TranslationSession` can only be had from
/// `translationTask`, so this sits once near the root and translates whatever has been queued.
private struct GenreTranslationHost: ViewModifier {
    private let localizer = GenreLocalizer.shared
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: localizer.pendingToken, initial: true) { startIfNeeded() }
            .translationTask(configuration) { session in
                let batch = localizer.takePending()
                var translations: [String: String] = [:]
                var failed: Set<String> = []
                if !batch.isEmpty {
                    let requests = batch.map {
                        TranslationSession.Request(sourceText: $0.value, clientIdentifier: $0.key)
                    }
                    do {
                        for response in try await session.translations(from: requests) {
                            guard let key = response.clientIdentifier else { continue }
                            translations[key] = response.targetText
                        }
                    } catch {
                        // Language pack declined or unsupported pair: leave the raw genres alone.
                    }
                    failed = Set(batch.keys).subtracting(translations.keys)
                }
                localizer.finish(translations: translations, failed: failed)
                configuration = nil
                startIfNeeded()
            }
    }

    private func startIfNeeded() {
        guard configuration == nil, localizer.hasPending, GenreLocalizer.appLanguage != "en" else { return }
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: localizer.language)
        )
    }
}

extension View {
    /// Lets `GenreLocalizer` translate the genres it has no entry for. Apply once, near the root.
    func genreTranslationHost() -> some View {
        modifier(GenreTranslationHost())
    }
}
