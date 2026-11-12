//
//  SearchView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

struct SearchView: View {
    @State var query = ""
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    
                }
                .navigationTitle("Search")
                .searchable(text: $query, placement: .toolbar, prompt: "Search")
            }
            .screenOnStack()
            .toolbar {
                filterButton
                SettingsToolbarItem()
            }
        }
        .environment(\.appTab, AppNavigation.searchTab)
    }
    
    @ToolbarContentBuilder
        private var filterButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "line.horizontal.3.decrease")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
}

#Preview {
    SearchView()
}
