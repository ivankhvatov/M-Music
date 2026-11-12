//
//  SettingsMenuButton.swift
//  M-Music
//

import SwiftUI

/// The gear in the top bar of each tab's root screen: a menu that opens one of the settings
/// screens as a bottom sheet. Use it as `SettingsToolbarItem()` inside `.toolbar { }`.
struct SettingsToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            SettingsMenuButton()
        }
    }
}

struct SettingsMenuButton: View {
    @State private var sheet: SettingsSheet?

    private enum SettingsSheet: String, Identifiable {
        case server, playback, downloads, appearance
        var id: String { rawValue }
    }

    var body: some View {
        Menu {
            Button { sheet = .server } label: {
                Label("Server", systemImage: "server.rack")
            }
            Button { sheet = .playback } label: {
                Label("Playback", systemImage: "play.circle")
            }
            Button { sheet = .downloads } label: {
                Label("Downloads", systemImage: "square.and.arrow.down")
            }
            Button { sheet = .appearance } label: {
                Label("Appearance", systemImage: "paintbrush")
            }
        } label: {
            Image(systemName: "gear")
                .foregroundStyle(Color.accentColor)
        }
        .tint(.accentColor)
        // The settings screens expect a navigation stack (they set their own title and don't
        // bring a bar), so each sheet gets one, plus a close button.
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                content(for: sheet)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .close) { self.sheet = nil }
                        }
                    }
            }
        }
    }

    /// Built only when its sheet is presented — `PlaybackSettingsView` alone has ~17
    /// `@AppStorage` properties.
    @ViewBuilder
    private func content(for sheet: SettingsSheet) -> some View {
        switch sheet {
        case .server: ServerSettingsView()
        case .playback: PlaybackSettingsView()
        case .downloads: DownloadsSettingsView()
        case .appearance: AppearanceSettingsView()
        }
    }
}
