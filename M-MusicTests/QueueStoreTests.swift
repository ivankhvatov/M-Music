import Foundation
import Testing
@testable import M_Music

private func song(_ id: String) -> Child {
    DownloadRecord(
        songId: id, title: "T\(id)", artist: "A", album: "Al", albumId: "al-1", coverArt: nil, track: 1,
        discNumber: nil, duration: 100, year: nil, genre: nil, filePath: "/x/\(id).flac", fileExtension: "flac",
        contentType: nil, bitRate: nil, byteSize: 1, replayGainTrackGain: nil, replayGainAlbumGain: nil,
        addedAt: Date(timeIntervalSince1970: 0), format: nil
    ).asChild()
}

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).json")
}

struct QueueStoreTests {
    @Test func roundTripsALargeQueue() async {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = (0..<5000).map { song("s\($0)") }
        let store = QueueStore(fileURL: url, debounce: .milliseconds(20))
        await store.save(queue: queue)
        await store.flush()
        let loaded = await QueueStore(fileURL: url).load()
        #expect(loaded == queue)
    }

    @Test func aBurstOfSavesWritesOnceAfterTheDebounce() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueueStore(fileURL: url, debounce: .milliseconds(80))
        for i in 0..<20 { await store.save(queue: [song("a\(i)")]) }
        #expect(!FileManager.default.fileExists(atPath: url.path))   // still debouncing
        try await Task.sleep(for: .milliseconds(400))
        #expect(await QueueStore(fileURL: url).load() == [song("a19")])
    }

    @Test func savingTheSameQueueAgainDoesNotRewriteTheFile() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = [song("x"), song("y")]
        let store = QueueStore(fileURL: url, debounce: .milliseconds(10))
        await store.save(queue: queue)
        await store.flush()
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(1100))
        await store.save(queue: queue)
        await store.flush()
        let second = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(first == second)
    }

    @Test func clearRemovesTheFile() async {
        let url = tempFile()
        let store = QueueStore(fileURL: url, debounce: .milliseconds(10))
        await store.save(queue: [song("x")])
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await store.load() == nil)
    }
}

@MainActor
struct PlaybackProgressTests {
    @Test func onlyChangesAreApplied() {
        let progress = PlaybackProgress.shared
        progress.update(currentTime: 12, duration: 200)
        #expect(progress.currentTime == 12)
        #expect(progress.duration == 200)
        progress.update(currentTime: 13)
        #expect(progress.currentTime == 13)
        #expect(progress.duration == 200)
        progress.update(currentTime: 0, duration: 0)
    }
}
