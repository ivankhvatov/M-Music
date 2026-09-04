//
//  PlaylistsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct PlaylistsListView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {

                }
                .navigationTitle("Playlists")
                .searchable(text: $searchText, prompt: "Search playlists")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    PlaylistsListView()
}
