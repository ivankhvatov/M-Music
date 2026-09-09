//
//  DownloadsSettingsView.swift
//  M-Music
//
//  Created by Ivan on 03.09.2026.
//

import SwiftUI

struct DownloadsSettingsView: View {
    @ObservedObject private var downloads = DownloadStore.shared
    @State private var showingDeleteAllConfirmation = false

    private var recordsByAlbum: [(albumId: String?, albumTitle: String, records: [DownloadRecord])] {
        let grouped = Dictionary(grouping: downloads.downloadedRecords) { $0.albumId }
        return grouped
            .map { albumId, records in
                (albumId: albumId, albumTitle: records.first?.album ?? String(localized: "Unknown Album"), records: records)
            }
            .sorted { $0.albumTitle.sortKey < $1.albumTitle.sortKey }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Total size")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Downloaded songs")
                        Spacer()
                        Text("\(downloads.downloadedRecords.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                if !downloads.downloadedRecords.isEmpty {
                    ForEach(recordsByAlbum, id: \.albumTitle) { group in
                        Section(group.albumTitle) {
                            ForEach(group.records.sorted { ($0.track ?? 0) < ($1.track ?? 0) }) { record in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.title)
                                        if let artist = record.artist {
                                            Text(artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        downloads.remove(songId: record.songId)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        Button("Delete All Downloads", role: .destructive) {
                            showingDeleteAllConfirmation = true
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Songs and albums you download will appear here.")
                    )
                }
            }
            .navigationTitle("Downloads")
            .confirmationDialog(
                "Delete all downloads?", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible
            ) {
                Button("Delete All Downloads", role: .destructive) {
                    downloads.removeAll()
                }
            }
        }
    }
}

#Preview {
    DownloadsSettingsView()
}
