//
//  RadioView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

struct RadioView: View {
    @State private var stations: [InternetRadioStation] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false
    /// Why the last "Delete station" failed, shown in an alert.
    @State private var deleteError: String?
    /// Mirrored from `PlayerManager` via `onReceive` rather than observing it directly, which
    /// would re-render this whole list on every playback-time tick.
    @State private var playingStationId: FlexibleID? = PlayerManager.shared.currentRadioStation?.id

    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @Environment(\.displayScale) private var displayScale
    /// Where the user last was in the station list, to warm around on resume — see `onAppResume`.
    @State private var lastSeen = LastSeenIndex()

    private let client = SubsonicClient.shared

    var body: some View {
        NavigationStack {
            Group {
                if !client.isConfigured {
                    disconnectedContent
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if stations.isEmpty {
                    Text("No radio stations found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stationsList
                }
            }
            .onAppResume { warmAround(lastSeen.index) }
            .navigationTitle("Radio")
            .screenOnStack()
            .toolbar {
                editButton
                SettingsToolbarItem()
            }
        }
        .environment(\.appTab, AppNavigation.radioTab)
        .alert("Couldn't delete the station", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .task { await refresh() }
        .onReceive(PlayerManager.shared.$currentRadioStation.map { $0?.id }.removeDuplicates()) { id in
            playingStationId = id
        }
    }

    private var stationsList: some View {
        List {
            ForEach(stations) { station in
                Button {
                    PlayerManager.shared.playRadio(station)
                } label: {
                    RadioStationRow(
                        station: station,
                        isPlaying: playingStationId == station.id,
                        displayScale: displayScale,
                        onDelete: { delete(station) }
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .disabled(!networkMonitor.isOnline)
                .onAppear {
                    guard let index = stations.firstIndex(where: { $0.id == station.id }) else { return }
                    lastSeen.index = index
                    warmAround(index)
                }
            }
        }
        .listStyle(.plain)
        .reportsScrollActivity()
    }

    /// Warms the artwork of the stations around `index` — a row appeared, or the app resumed.
    private func warmAround(_ index: Int) {
        let size = Int(64 * displayScale)
        let requests = ImageWarmer.neighbors(of: index, in: stations, count: ImageWarmer.scrollAheadCount)
            .compactMap { station in
                station.coverArt.map {
                    ArtworkRequest(id: $0, size: size, maxPixelSize: ImageCache.standardMaxPixelSize)
                }
            }
        guard !requests.isEmpty else { return }
        Task { await ImageWarmer.shared.warmAhead(requests, source: "radio") }
    }

    /// Removes `station` from the server's library, then from the list, stopping it if it's the one
    /// playing — only once the server has confirmed it, so a failure (offline, or a user without
    /// admin rights) leaves the row and its playback in place.
    private func delete(_ station: InternetRadioStation) {
        Task {
            do {
                try await client.deleteInternetRadioStation(id: station.id.raw)
                PlayerManager.shared.stopRadio(ifPlaying: station.id)
                stations.removeAll { $0.id == station.id }
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 16) {
            Text("Connect to your Navidrome server to get started")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            NavigationLink(destination: LazyDestination { ServerSettingsView() }) {
                Text("Connect")
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 120)
    }

    /// Only the very first load shows the spinner; later appearances revalidate quietly and only
    /// touch the displayed list if the server's answer actually differs (compared in
    /// `LibraryLoader`, off the main actor).
    private func refresh() async {
        guard client.isConfigured else {
            stations = []
            hasLoadedOnce = false
            return
        }
        if !hasLoadedOnce {
            isLoading = true
        }
        defer { isLoading = false }
        for await event in LibraryLoader.load(.radioStations(), shown: stations) {
            switch event {
            case .cached:
                break
            case .fresh(let fetched):
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
                stations = fetched
            case .upToDate:
                loadError = nil
                isLoading = false
                hasLoadedOnce = true
            case .failed(let error):
                // Keep showing whatever's already on screen; only surface an error if there's
                // truly nothing to show.
                isLoading = false
                if stations.isEmpty {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    @ToolbarContentBuilder
        private var editButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
}

/// A single row for the radio stations list — the same layout as `AlbumsListView.AlbumRow`
/// (rounded-corner artwork, name/subtitle stacked next to it), but a plain tappable row rather
/// than a navigation link: the trailing chevron becomes an ellipsis menu, and tapping the rest
/// of the row starts the station streaming instead of pushing a screen.
private struct RadioStationRow: View {
    let station: InternetRadioStation
    let isPlaying: Bool
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    /// Computed once, in `init` — see `AlbumRow.artworkURL`. `nil` when the station has no cover
    /// art (older Navidrome servers, or nothing uploaded), which shows the placeholder.
    @State private var artworkURL: URL?

    private let rowArtworkSize: CGFloat = 64
    private let artworkCornerRadius: CGFloat = 4

    init(station: InternetRadioStation, isPlaying: Bool, displayScale: CGFloat, onDelete: @escaping () -> Void) {
        self.station = station
        self.isPlaying = isPlaying
        self.onDelete = onDelete
        let pixelSize = Int(rowArtworkSize * displayScale)
        _artworkURL = State(initialValue: station.coverArt.flatMap {
            try? SubsonicClient.shared.coverArtURL(forId: $0, size: pixelSize)
        })
    }

    var body: some View {
        HStack(spacing: 16) {
            artwork

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.system(size: 18))
                    .foregroundStyle(isPlaying ? Color.red : Color.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            stationMenu
        }
        .dimmedIfUnavailable(NetworkMonitor.shared.isOnline)
    }

    /// Styled like `AlbumView`'s track menu.
    private var stationMenu: some View {
        Menu {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label { Text("Delete station") } icon: { redMenuSymbol("trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.primary)
                .font(.system(size: 18))
                // Enlarges the tappable area well past the glyph itself without changing how it
                // looks.
                .frame(width: 32, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .confirmationDialog(
            "Delete the station from the library?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    /// The station's website host ("www." dropped), or a generic label when it has none.
    private var subtitle: String {
        guard let host = station.homepageUrl.flatMap({ URL(string: $0)?.host }), !host.isEmpty else {
            return String(localized: "Live Radio")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: artworkCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: artworkCornerRadius)
                        .stroke(Color.secondary, lineWidth: 0.1)
                )
        } placeholder: {
            RoundedRectangle(cornerRadius: artworkCornerRadius)
                .fill(Color.secondary.opacity(0.15))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: rowArtworkSize, height: rowArtworkSize)
    }
}

#Preview {
    RadioView()
}
