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
    @AppStorage(DownloadTranscodingSettings.Keys.isEnabled) private var isDownloadTranscodingEnabled = false
    @AppStorage(DownloadTranscodingSettings.Keys.format) private var downloadFormat = TranscodingFormat.mp3
    @AppStorage(DownloadTranscodingSettings.Keys.bitrate) private var downloadBitrate = TranscodingBitrate.k192
    // Default here must match DownloadTranscodingSettings.defaultPrioritizeDownloads.
    @AppStorage(DownloadTranscodingSettings.Keys.prioritizeDownloads) private var prioritizeDownloads = true
    @AppStorage(DownloadConversionSettings.Keys.convertLosslessToALAC) private var convertLosslessToALAC = false
    @AppStorage(DownloadConversionSettings.Keys.convertOpusToCAF) private var convertOpusToCAF = false

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
                    Toggle("Enable download transcoding", isOn: $isDownloadTranscodingEnabled)

                    Picker("Format", selection: $downloadFormat) {
                        ForEach(TranscodingFormat.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isDownloadTranscodingEnabled)

                    Picker("Bitrate", selection: $downloadBitrate) {
                        ForEach(TranscodingBitrate.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isDownloadTranscodingEnabled)

                    Toggle("Prioritize downloads", isOn: $prioritizeDownloads)
                } header: {
                    Text("Download format")
                } footer: {
                    Text("Format/bitrate apply only to new downloads — songs already saved to this device keep whatever quality they were downloaded at. When Prioritize downloads is on, a downloaded song always plays from the download regardless of its format; when off, a download only plays if its format still matches the current Transcoding setting in Playback settings, otherwise the gapless cache or streaming is used instead.")
                }

                Section {
                    Toggle("Convert lossless to ALAC", isOn: $convertLosslessToALAC)
                    Toggle("Convert Opus to .caf", isOn: $convertOpusToCAF)
                } header: {
                    Text("Conversion")
                } footer: {
                    Text("Applies only to new downloads — songs already saved to this device keep whatever container they were downloaded in. Lossless downloads (FLAC, WAV, AIFF) are converted to Apple Lossless (ALAC); Opus downloads are repackaged into a .caf container. Both keep full audio quality — no lossy re-encoding is involved.")
                }

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
                    Section {
                        Button("Delete All Downloads", role: .destructive) {
                            showingDeleteAllConfirmation = true
                        }
                    }

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
