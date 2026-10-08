//
//  SearchView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

struct SearchView: View {
    @State var query = ""
    @Bindable private var navigation = AppNavigation.shared
    
    var body: some View {
        NavigationStack(path: $navigation.paths[AppNavigation.searchTab]) {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    
                }
                .navigationTitle("Search")
                .searchable(text: $query, placement: .toolbar, prompt: "Search")
            }
            .appRouteDestinations()
            .toolbar {
                filterButton
                settingsButton
            }
        }
    }
    
    @ToolbarContentBuilder
        private var filterButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "line.horizontal.3.decrease")
                        .foregroundStyle(.primary)
                }
            }
        }
    
    @ToolbarContentBuilder
        private var settingsButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.primary)
                }
            }
        }
}

#Preview {
    SearchView()
}
