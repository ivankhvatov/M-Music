//
//  ServerSettingsView.swift
//  M-Music
//
//  Created by Ivan on 03.09.2026.
//

import SwiftUI

struct ServerSettingsView: View {
    private let client = SubsonicClient.shared

    @State private var serverURL: String = SubsonicClient.shared.credentials?.baseURL.absoluteString ?? ""
    @State private var username: String = SubsonicClient.shared.credentials?.username ?? ""
    @State private var password: String = SubsonicClient.shared.credentials?.password ?? ""

    @State private var isConnected: Bool = SubsonicClient.shared.isConfigured
    @State private var isConnecting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        // No `NavigationStack` of its own: this is pushed onto `LibraryView`'s stack, which
        // already provides the bar and title — a second one meant a second navigation controller
        // and glass bar, with keyboard safe-area changes propagating through both.
        VStack(alignment: .leading, spacing: 10) {
            List {
                Section {
                    TextField("https://music.example.com", text: $serverURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Navidrome Server")
                } footer: {
                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text("Enter the address of your Navidrome server, e.g. https://music.example.com or http://192.168.1.10:4533")
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(isConnected ? "Reconnect" : "Connect")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    if isConnected {
                        Button(role: .destructive) {
                            disconnect()
                        } label: {
                            Text("Disconnect")
                                .frame(maxWidth: .infinity)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
            }
            .navigationTitle("Server")
        }
    }

    private func connect() {
        errorMessage = nil
        statusMessage = nil

        var trimmedURLString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedURLString.contains("://") {
            trimmedURLString = "https://" + trimmedURLString
        }
        guard let url = URL(string: trimmedURLString) else {
            errorMessage = "That doesn't look like a valid server address."
            return
        }

        isConnecting = true
        Task {
            do {
                let license = try await client.connect(baseURL: url, username: username, password: password)
                isConnecting = false
                isConnected = true
                statusMessage = license.valid
                    ? "Connected to \(url.host ?? url.absoluteString)."
                    : "Connected, but the server's license is not valid."
            } catch {
                isConnecting = false
                isConnected = client.isConfigured
                errorMessage = error.localizedDescription
            }
        }
    }

    private func disconnect() {
        // The UI state flips immediately; the Keychain/cache file I/O inside `client.disconnect()`
        // runs off the main thread (it's `nonisolated async`), so tapping Disconnect can't hitch.
        isConnected = false
        statusMessage = nil
        errorMessage = nil
        Task { await client.disconnect() }
    }
}

#Preview {
    ServerSettingsView()
}
