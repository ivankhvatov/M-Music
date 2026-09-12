//
//  AppearanceSettingsView.swift
//  M-Music
//
//  Created by Ivan on 09.09.2026.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("library.separateReleaseTypes") private var separateReleaseTypesEnabled = false
    @AppStorage("library.groupReleaseVersions") private var groupReleaseVersionsEnabled = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                List {
                    Section {
                        Toggle("Separate artist's release types", isOn: $separateReleaseTypesEnabled)
                        Toggle("Group release versions", isOn: $groupReleaseVersionsEnabled)
                    } header: {
                        Text("Library")
                    } footer: {
                        Text("Separate artist's release types shows an artist's albums, EPs, singles, and other release types as separate rows instead of one grid; artists with only one release type are unaffected. Group release versions collapses multiple versions of the same album (e.g. a Deluxe or Remastered edition) down to just the plain edition, or the one with the shortest version name if there's no plain edition — except when Albums is filtered to Favorite only.")
                    }
                }
                .navigationTitle("Appearance")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    AppearanceSettingsView()
}
