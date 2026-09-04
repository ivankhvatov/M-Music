//
//  SongsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct SongsListView: View {
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {

                }
                .navigationTitle("Songs")
                .searchable(text: $searchText, prompt: "Search songs")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    SongsListView()
}
