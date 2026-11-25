//
//  CreatePlaylistAlerts.swift
//  M-Music
//

import SwiftUI

extension View {
    /// The "Create a playlist" flow behind the plus buttons on the Playlists screen and on
    /// Library: a name prompt, then an empty playlist created on the server, and an alert if that
    /// fails. Set `isPresented` to start it.
    ///
    /// - `existingNames`: the playlists' current names, read only when the name was left blank, to
    ///   pick the smallest unused "New Playlist N".
    /// - `onCreated`: runs once the server has the playlist, to refresh whatever shows the list.
    func createPlaylistAlerts(
        isPresented: Binding<Bool>,
        existingNames: @escaping () async -> [String],
        onCreated: @escaping () async -> Void
    ) -> some View {
        modifier(CreatePlaylistAlerts(isPresented: isPresented, existingNames: existingNames, onCreated: onCreated))
    }
}

private struct CreatePlaylistAlerts: ViewModifier {
    @Binding var isPresented: Bool
    let existingNames: () async -> [String]
    let onCreated: () async -> Void

    @State private var name = ""
    @State private var error: String?

    private let client = SubsonicClient.shared

    func body(content: Content) -> some View {
        content
            .alert("Create a playlist", isPresented: $isPresented) {
                TextField("Playlist name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    let typed = name
                    name = ""
                    create(named: typed)
                }
            }
            .alert("Couldn't create the playlist", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    /// Creates an empty playlist on the server, then lets the caller refresh its list.
    private func create(named typed: String) {
        Task {
            var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = Self.defaultName(avoiding: await existingNames()) }
            do {
                try await client.createPlaylist(name: name)
                await onCreated()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// "New Playlist N" (localized) with the smallest N no existing playlist already uses,
    /// ignoring case.
    private static func defaultName(avoiding existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        var number = 1
        while taken.contains(String(localized: "New Playlist \(number)").lowercased()) {
            number += 1
        }
        return String(localized: "New Playlist \(number)")
    }
}
