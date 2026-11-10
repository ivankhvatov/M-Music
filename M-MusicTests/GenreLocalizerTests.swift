import Foundation
import Testing
@testable import M_Music

@MainActor
struct GenreLocalizerTests {
    private func localizer(_ language: String, enabled: Bool = true) -> GenreLocalizer {
        GenreLocalizer(
            language: language, isEnabled: { enabled }, cacheURL: nil,
            entriesURL: Bundle.main.url(forResource: "LocalizedGenres", withExtension: "json")
        )
    }

    @Test func aListedGenreIsShownInTheAppLanguage() {
        #expect(localizer("de").localized("hip hop") == "Hip-Hop")
        #expect(localizer("ru").localized("Death Metal") == "Дэт-метал")
        #expect(localizer("en").localized("hip-hop") == "Hip Hop")
    }

    @Test func aGenreInAnotherLanguageOfTheListIsFoundToo() {
        #expect(localizer("ru").localized("Klassische Musik") == "Классическая музыка")
    }

    @Test func theRawGenreStaysWhileTheSwitchIsOff() {
        #expect(localizer("ru", enabled: false).localized("Death Metal") == "Death Metal")
    }

    @Test func eachPartOfAMultiGenreTagIsLocalized() {
        #expect(localizer("ru").localized("Rock; Jazz") == "Рок; Джаз")
        #expect(localizer("de").localized("Soul/Funk") == "Soul/Funk")
    }

    @Test func anUnlistedGenreIsQueuedOnceAndShownRawUntilTranslated() {
        let l = localizer("de")
        #expect(l.localized("Zydeco") == "Zydeco")
        #expect(l.localized("zydeco") == "zydeco")
        #expect(l.takePending() == ["zydeco": "Zydeco"])
        #expect(!l.hasPending)
    }

    @Test func aTranslatedGenreIsServedFromTheCache() {
        let l = localizer("de")
        _ = l.localized("Zydeco")
        let batch = l.takePending()
        l.finish(translations: ["zydeco": "Zydeko"], failed: [])
        #expect(batch.count == 1)
        #expect(l.localized("Zydeco") == "Zydeko")
        #expect(!l.hasPending)
    }

    @Test func aFailedGenreIsNotQueuedAgain() {
        let l = localizer("de")
        _ = l.localized("Zydeco")
        _ = l.takePending()
        l.finish(translations: [:], failed: ["zydeco"])
        _ = l.localized("Zydeco")
        #expect(!l.hasPending)
    }

    @Test func englishNeverQueuesAnything() {
        let l = localizer("en")
        #expect(l.localized("Zydeco") == "Zydeco")
        #expect(!l.hasPending)
    }

    @Test func clearingForgetsTheTranslationsAndTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("genres-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let l = GenreLocalizer(
            language: "de", isEnabled: { true }, cacheURL: url,
            entriesURL: Bundle.main.url(forResource: "LocalizedGenres", withExtension: "json")
        )
        _ = l.localized("Zydeco")
        _ = l.takePending()
        l.finish(translations: ["zydeco": "Zydeko"], failed: [])
        #expect(FileManager.default.fileExists(atPath: url.path))
        l.clearTranslations()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(l.localized("Zydeco") == "Zydeco")
        #expect(l.hasPending)
    }
}
