//
//  PlaylistsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct PlaylistsListView: View {
    @Namespace private var playlistZoomNamespace

    private let client = SubsonicClient.shared

    @State private var searchText = ""

    @State private var playlists: [PlaylistSummary] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoadedOnce = false

    private let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                playlistsGrid
            }
            .navigationTitle("Playlists")
            .searchable(text: $searchText, prompt: "Search")
            .onAppear {
                refresh()
            }
        }
    }

    @ViewBuilder
    private var playlistsGrid: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else if let loadError {
            Text(loadError)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        } else if displayedPlaylists.isEmpty {
            Text("No playlists found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(displayedPlaylists) { playlist in
                    NavigationLink(destination: PlaylistView(playlist: playlist, zoomNamespace: playlistZoomNamespace)) {
                        PlaylistCardView(playlist: playlist, zoomNamespace: playlistZoomNamespace)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var displayedPlaylists: [PlaylistSummary] {
        guard !searchText.isEmpty else { return playlists }
        return playlists.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.owner?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func refresh() {
        guard client.isConfigured else {
            playlists = []
            hasLoadedOnce = false
            return
        }
        guard !isLoading else { return }

        if !hasLoadedOnce {
            isLoading = true
        }
        Task {
            do {
                let fetched = try await client.getPlaylists()
                await MainActor.run {
                    playlists = fetched
                    loadError = nil
                    isLoading = false
                    hasLoadedOnce = true
                }
            } catch {
                await MainActor.run {
                    if !hasLoadedOnce {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    PlaylistsListView()
}
