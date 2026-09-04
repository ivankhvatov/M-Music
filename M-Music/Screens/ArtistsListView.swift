//
//  ArtistsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct ArtistsListView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {

                }
                .navigationTitle("Artists")
                .searchable(text: $searchText, prompt: "Search artists")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    ArtistsListView()
}
