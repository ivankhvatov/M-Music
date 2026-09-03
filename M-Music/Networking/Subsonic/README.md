# Subsonic / Navidrome API client

A Swift client for talking to a [Navidrome](https://www.navidrome.org) server over the
[Subsonic API](https://www.subsonic.org/pages/api.jsp). It implements every endpoint
[Navidrome supports](https://www.navidrome.org/docs/developers/subsonic-api/) (API v1.16.1,
JSON transport, token authentication) — browsing, lists, search, playlists, streaming/cover
art/lyrics, favorites & ratings, scrobbling, sharing, internet radio, bookmarks/play queue,
user info, and library scanning.

It deliberately does **not** implement the parts of the Subsonic spec Navidrome itself
doesn't support: video (`getVideos`, `getVideoInfo`, `getCaptions`, `hls`), `jukeboxControl`,
the Podcast endpoints, chat, and user creation/editing (`createUser`/`updateUser`/`deleteUser`/
`changePassword` — Navidrome only exposes `getUser`/`getUsers`).

## Where things live

```
M-Music/Networking/Subsonic/
├── Core/
│   ├── SubsonicClient.swift        the client: auth, URL building, request/decode
│   ├── SubsonicCredentials.swift   credential struct + Keychain/UserDefaults persistence
│   ├── Keychain.swift              tiny Keychain Services wrapper
│   ├── SubsonicPayload.swift       generic envelope decoding + error types
│   ├── FlexibleID.swift            id type that accepts server-supplied String or Int
│   └── AlbumDetailsCache.swift     in-memory cache for getAlbum, keyed by album id
├── Models/
│   ├── SubsonicModels+Media.swift   Child (song), Directory, Artist/Album (ID3), search, lists...
│   └── SubsonicModels+Extras.swift  playlists, lyrics, bookmarks, sharing, radio, users, scanning
└── Endpoints/
    SubsonicClient+System.swift, +Browsing.swift, +Lists.swift, +Search.swift,
    +Playlists.swift, +Media.swift, +Annotation.swift, +Sharing.swift, +Radio.swift,
    +Users.swift, +Bookmarks.swift, +Scanning.swift
```

Each file under `Endpoints/` groups the methods the way the Subsonic docs do, so if you're
looking for e.g. `getAlbumList2`, check `SubsonicClient+Lists.swift`.

## Connecting

`SubsonicClient.shared` is a singleton. On launch it tries to restore a previously saved
server from `UserDefaults`/Keychain automatically — check `client.isConfigured` before
assuming you need to prompt for a server.

```swift
let client = SubsonicClient.shared

do {
    let license = try await client.connect(
        baseURL: URL(string: "https://music.example.com")!,
        username: "ivan",
        password: "hunter2"
    )
    print("Connected, license valid: \(license.valid)")
} catch {
    print(error.localizedDescription) // human-readable, see SubsonicError below
}
```

`connect(baseURL:username:password:)` calls `getLicense` to verify the credentials actually
work *before* persisting anything — if it throws, whatever was previously configured (if
anything) is left untouched. On success the server URL and username are saved to
`UserDefaults` and the password to the Keychain, so they survive relaunches.

```swift
client.disconnect() // clears everything, in-memory and persisted
```

A working example of this flow is wired up in
[`ServerSettingsView`](../../Screens/Settings/ServerSettingsView.swift).

## Making calls

Every endpoint is an `async throws` method directly on `SubsonicClient`, grouped into
`extension SubsonicClient { ... }` blocks under `Endpoints/`. There's no separate
"repository" or "service" layer to go through — call them straight from a view model or a
SwiftUI `.task`:

```swift
struct AlbumsScreen: View {
    @State private var albums: [AlbumID3] = []
    @State private var errorMessage: String?

    var body: some View {
        List(albums) { album in
            Text(album.name)
        }
        .task {
            do {
                albums = try await SubsonicClient.shared.getAlbumList2(type: .newest, size: 50)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
```

### Browsing (tag-based / "ID3" — the recommended way)

```swift
let artists = try await client.getArtists()              // ArtistsID3, grouped by index letter
let artist  = try await client.getArtist(id: someId)      // ArtistWithAlbumsID3
let album   = try await client.getAlbum(id: someId)       // AlbumWithSongsID3 (has .song)
let genres  = try await client.getGenres()                // [Genre]
```

Folder-based browsing (`getMusicFolders`, `getIndexes`, `getMusicDirectory`) also works, but
per Navidrome's own docs it returns a *simulated* directory tree built from tags, not real
filesystem folders — prefer the ID3 calls above unless you specifically need folder
semantics.

`AlbumID3`/`AlbumWithSongsID3` also carry `recordLabels: [RecordLabel]` and
`releaseTypes: [String]`, sourced from the LABEL/RECORDLABEL and RELEASETYPE tags on the
album's tracks. These are OpenSubsonic extensions Navidrome only aggregates and exposes at
the **album** level, never per-song, even though the tags themselves live on the track
files — there's no `Child`/song equivalent to fetch. A COPYRIGHT tag, if your server parses
one, is **not** exposed anywhere in the Subsonic/OpenSubsonic API at all (verified against
Navidrome's own response-builder source) — there's no field this client (or any Subsonic
client) can read it from; only Navidrome's own web UI can show it, via its separate native
REST API.

Neither Subsonic nor OpenSubsonic has a dedicated codec tag either. `Child.codec` derives one
from `suffix` (the file extension, e.g. "flac" → "FLAC"), and `AlbumWithSongsID3.codec` takes
its first track's — both computed client-side, not decoded from a server field.

`getAlbum` (full album details, including the track list) is fetched often — every time a
user opens an album — so it's worth caching. `AlbumDetailsCache` wraps it with a keyed-by-id
cache, backed by an in-memory dictionary and mirrored to disk (`Caches/SubsonicAlbumCache/`),
so reopening an album already seen — this session *or* a previous one — is instant instead of
a round trip:

```swift
let full = try await AlbumDetailsCache.shared.album(id: album.id.raw) // AlbumWithSongsID3
```

The cache is cleared automatically on `connect`/`disconnect` (switching servers or accounts
invalidates it, memory and disk), and can be dropped manually with `invalidate(id:)` or
`invalidateAll()` — e.g. after an edit that could change an album's track list. It never
expires or evicts on its own otherwise, so a long-lived install accumulates one small JSON
file per album ever opened; `Caches/` is a directory the OS is free to purge under storage
pressure, so this is safe to leave unbounded. See it in use in
[`AlbumView`](../../Screens/AlbumView.swift). Nothing else is cached this way; every other
endpoint always hits the network, matching `SubsonicClient` itself never caching (see Design
notes below).

### Lists & search

```swift
let recent = try await client.getAlbumList2(type: .recent, size: 20)
let random = try await client.getRandomSongs(size: 25, genre: "Death Metal")
let results = try await client.search3(query: "archspire") // .artist / .album / .song
let starred = try await client.getStarred2()                // favorited artists/albums/songs
```

`AlbumListType` covers every `type` value Navidrome accepts for `getAlbumList`/`getAlbumList2`:
`.random .newest .frequent .recent .starred .alphabeticalByName .alphabeticalByArtist .byYear
.byGenre` (plus `.highest`, which only `getAlbumList`, not `getAlbumList2`, supports).

### Streaming & artwork

Media endpoints return binary data, so `SubsonicClient` exposes **synchronous URL builders**
(no `await` needed) that you can hand straight to `AVPlayer` or `AsyncImage`:

```swift
// Playback
let item = AVPlayerItem(url: try client.streamURL(forId: song.id.raw))
player.replaceCurrentItem(with: item)

// Artwork
AsyncImage(url: try? client.coverArtURL(forId: album.id.raw, size: 300)) { image in
    image.resizable().aspectRatio(contentMode: .fill)
} placeholder: {
    Color.gray.opacity(0.2)
}
```

`streamURL(forId:maxBitRate:format:)` lets the server transcode (cap the bitrate, force a
format) or pass `format: "raw"` to force the original file. `downloadURL(forId:)` always
returns the original file — use it for an offline-download feature. If you need the bytes
in memory instead of a URL, `downloadData(forId:)` and `coverArtData(forId:size:)` are the
`async` equivalents.

### Favorites, ratings, scrobbling

```swift
try await client.star(ids: [song.id.raw])
try await client.unstar(ids: [song.id.raw])
try await client.setRating(id: album.id.raw, rating: 5)

// Call when playback starts (updates "now playing" for other clients):
try await client.scrobble(ids: [song.id.raw], submission: false)
// Call once playback has gone on long enough to count as a play:
try await client.scrobble(ids: [song.id.raw], submission: true)
```

Navidrome only marks a song as "played" via an explicit `scrobble(submission: true)` call —
just streaming the file does not increment play count, so playback code needs to call this
itself (e.g. after a few seconds of playback, or on completion).

### Playlists

```swift
let playlists = try await client.getPlaylists()
let playlist  = try await client.getPlaylist(id: playlists[0].id.raw)   // includes .entry (songs)

try await client.createPlaylist(name: "Road trip", songIds: [id1, id2])
try await client.updatePlaylist(playlistId: playlist.id.raw, songIdsToAdd: [id3])
try await client.deletePlaylist(id: playlist.id.raw)
```

### Everything else

Bookmarks & cross-device play queue (`getBookmarks`, `createBookmark`, `getPlayQueue`,
`savePlayQueue`), sharing (`getShares`, `createShare`, ...), internet radio stations
(`getInternetRadioStations`, `createInternetRadioStation`, ...), the current user's account
info (`getCurrentUser`), and library scan status/triggering (`getScanStatus`, `startScan`)
all follow the exact same pattern — see the corresponding file under `Endpoints/` for the
full method list and doc comments.

## Error handling

Every method throws `SubsonicError` (or a `URLSession` error wrapped into one):

```swift
enum SubsonicError {
    case notConfigured        // no server connected yet — call connect(...) first
    case invalidBaseURL
    case invalidResponse
    case http(status: Int)    // non-2xx HTTP status
    case decoding(String)     // response didn't match the expected JSON shape
    case server(code: Int, message: String)  // server rejected the request (wrong password, not found, ...)
}
```

`error.localizedDescription` (via `LocalizedError`) already turns the standard Subsonic API
error codes (wrong password, unauthorized, expired trial, not found, ...) into a readable
sentence, so in most UI code you can just display it directly:

```swift
} catch {
    errorMessage = error.localizedDescription // e.g. "Wrong username or password."
}
```

## IDs

Navidrome IDs are opaque strings (MD5 hashes/UUIDs), but the wider Subsonic spec allows
plain integers too. Every model uses `FlexibleID` instead of `String` for id fields so the
client works against either kind of server without extra code — get the string value with
`.raw` (e.g. `song.id.raw`), or just interpolate it (`FlexibleID` is `CustomStringConvertible`).

## Design notes

- **JSON, not XML.** The client always requests `f=json`; there's no XML parsing anywhere.
- **Token auth.** Every request authenticates with the recommended `t`/`s` (salted MD5 token)
  scheme from API v1.13.0+, computed fresh per-request via `CryptoKit.Insecure.MD5` — the
  plaintext password only ever leaves the device inside that one-way hash.
- **GET vs POST.** Read-only calls use `GET`; anything that mutates state, or that can carry
  an unbounded number of repeated parameters (song ids on a playlist, star ids, ...), uses
  `POST` to avoid URL-length limits. Parameters are still sent as a query string either way —
  that's what Navidrome expects.
- **Why a plain class instead of an `actor`.** `SubsonicClient` is a `final class` with a
  lock around its mutable `credentials`, not an `actor`. That keeps URL-building methods
  (`coverArtURL`, `streamURL`, ...) synchronous, which matters because SwiftUI APIs like
  `AsyncImage(url:)` and `AVPlayerItem(url:)` need a plain `URL`, not something you `await`.
- **Generic envelope decoding.** Every Subsonic JSON response has the shape
  `{"subsonic-response": {"status", "version", "error"?, "<oneNamedKey>": ...}}` where the
  named key differs per endpoint (`"license"`, `"albumList2"`, `"artist"`, ...). Rather than
  hand-writing ~40 near-identical wrapper structs, `SubsonicResponse<Payload>` looks the key
  up dynamically via `Payload.responseKey` (see `SubsonicPayload.swift`) — each model just
  declares which key it lives under.
