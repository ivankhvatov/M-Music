//
//  SongsListView.swift
//  M-Music
//
//  Created by Ivan on 02.09.2026.
//

import SwiftUI

struct SongsListView: View {
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    
                }
                .navigationTitle("Songs")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    SongsListView()
}
