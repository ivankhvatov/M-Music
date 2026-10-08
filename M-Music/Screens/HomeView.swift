//
//  HomeView.swift
//  M-Music
//
//  Created by Ivan on 04.07.2026.
//

import SwiftUI

struct HomeView: View {
    @Bindable private var navigation = AppNavigation.shared

    var body: some View {
        NavigationStack(path: $navigation.paths[AppNavigation.homeTab]) {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    
                }
                .navigationTitle("Home")
            }
            .appRouteDestinations()
            .toolbar {
                moreButton
                settingsButton
            }
        }
    }
    
    @ToolbarContentBuilder
        private var moreButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button {} label: {
                    Image(systemName: "ellipsis")
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
    HomeView()
}
