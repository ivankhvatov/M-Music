import Foundation

/// The lyrics saved with downloaded songs (when "Download lyrics" is on in `DownloadsSettingsView`),
/// one small JSON file per song next to the downloads themselves. `LyricsLoader` reads a song's
/// from here before it asks the server, so a downloaded song's lyrics come from the device — and
/// are there offline — from the moment they were saved; deleting the download deletes them too.
actor DownloadedLyrics {
    static let shared = DownloadedLyrics()

    private init() {}

    private static var directory: URL {
        DownloadDatabase.rootDirectory().appendingPathComponent("Lyrics", isDirectory: true)
    }

    private func fileURL(songId: String) -> URL {
        Self.directory.appendingPathComponent("\(songId.pathSafeComponent).json")
    }

    /// The lyrics saved for the song, if any were.
    func lyrics(songId: String) -> LyricsSource? {
        guard let data = try? Data(contentsOf: fileURL(songId: songId)) else { return nil }
        return try? JSONDecoder().decode(LyricsSource.self, from: data)
    }

    /// Fetches the song's lyrics from the server and saves them. Best-effort: if the server
    /// couldn't be reached nothing is saved (a song that has none is, so it isn't asked again),
    /// and the lyrics keep coming from the server until they are.
    func download(songId: String, artist: String?, title: String) async {
        let result = await LyricsLoader.fetchFromServer(songId: songId, artist: artist, title: title)
        guard result.isDefinitive, let data = try? JSONEncoder().encode(result.source) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(songId: songId), options: .atomic)
    }

    func delete(songId: String) {
        try? FileManager.default.removeItem(at: fileURL(songId: songId))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: Self.directory)
    }
}
