//
//  PlaybackSettingsView.swift
//  M-Music
//
//  Created by Ivan on 03.09.2026.
//

import SwiftUI

struct PlaybackSettingsView: View {
    @AppStorage(TranscodingSettings.Keys.isEnabled) private var isTranscodingEnabled = false
    @AppStorage(TranscodingSettings.Keys.format) private var format = TranscodingFormat.mp3
    @AppStorage(TranscodingSettings.Keys.bitrate) private var bitrate = TranscodingBitrate.k192
    @AppStorage(TranscodingSettings.Keys.fileScope) private var fileScope = TranscodeFileScope.all
    @AppStorage(TranscodingSettings.Keys.network) private var network = TranscodeNetwork.both

    // Defaults here must match ReplayGainSettings.default* — see that type's doc comment.
    @AppStorage(ReplayGainSettings.Keys.isEnabled) private var isReplayGainEnabled = false
    @AppStorage(ReplayGainSettings.Keys.mode) private var replayGainMode = ReplayGainMode.track
    @AppStorage(ReplayGainSettings.Keys.preventClipping) private var preventClipping = true
    @AppStorage(ReplayGainSettings.Keys.preAmp) private var preAmp: Double = 0
    @AppStorage(ReplayGainSettings.Keys.defaultGain) private var defaultGain: Double = 0

    @AppStorage(GaplessCacheSettings.Keys.isEnabled) private var isGaplessCacheEnabled = false
    @AppStorage(GaplessCacheSettings.Keys.sizeLimit) private var gaplessCacheSizeLimit = GaplessCacheSizeLimit.mb500
    @AppStorage(GaplessCacheSettings.Keys.retention) private var gaplessCacheRetention = GaplessCacheRetention.day3
    @State private var gaplessCacheUsageBytes: Int64 = 0
    @State private var cachedRecords: [GaplessCacheRecord] = []
    @State private var isCachedListExpanded = false
    @State private var showingClearCacheConfirmation = false
    @AppStorage(ScrobbleSettings.Keys.isEnabled) private var isScrobblingEnabled = true
    @AppStorage(ScrobbleSettings.Keys.fromPlaylists) private var scrobbleFromPlaylists = true
    @AppStorage(ScrobbleSettings.Keys.threshold) private var scrobbleThreshold = ScrobbleSettings.defaultThreshold
    @AppStorage(GaplessCacheSettings.Keys.convertLosslessToALAC) private var convertLosslessToALAC = false
    @AppStorage(GaplessCacheSettings.Keys.convertOpusToCAF) private var convertOpusToCAF = false
    @State private var showingNeverConfirmation = false

    /// Picking "Never" wipes the persistent cache, so when there's something to lose it's held
    /// back behind a confirmation instead of applying — the picker stays on its current value
    /// unless the user confirms.
    private var retentionSelection: Binding<GaplessCacheRetention> {
        Binding(
            get: { gaplessCacheRetention },
            set: { newValue in
                if newValue == .never, gaplessCacheRetention != .never, !cachedRecords.isEmpty {
                    showingNeverConfirmation = true
                } else {
                    gaplessCacheRetention = newValue
                }
            }
        )
    }

    private let gainRange: ClosedRange<Double> = -15...15

    private struct CachedAlbumGroup: Identifiable {
        let id: String
        let title: String
        let songs: [GaplessCacheRecord]
    }

    private var cachedAlbumGroups: [CachedAlbumGroup] {
        Dictionary(grouping: cachedRecords) { $0.albumId ?? $0.album ?? "" }
            .map { key, records in
                CachedAlbumGroup(
                    id: key,
                    title: records.first?.album ?? String(localized: "Unknown Album"),
                    songs: records.sorted { $0.title.sortKey.localizedStandardCompare($1.title.sortKey) == .orderedAscending }
                )
            }
            .sorted { $0.title.sortKey.localizedStandardCompare($1.title.sortKey) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                Section {
                    Toggle("Enable transcoding", isOn: $isTranscodingEnabled)

                    Picker("Format", selection: $format) {
                        ForEach(TranscodingFormat.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isTranscodingEnabled)

                    Picker("Bitrate", selection: $bitrate) {
                        ForEach(TranscodingBitrate.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isTranscodingEnabled)

                    Picker("Files to transcode", selection: $fileScope) {
                        ForEach(TranscodeFileScope.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isTranscodingEnabled)

                    Picker("Transcode over", selection: $network) {
                        ForEach(TranscodeNetwork.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isTranscodingEnabled)
                } header: {
                    Text("Transcoding")
                } footer: {
                    Text("Transcoded tracks use less bandwidth and storage, at the cost of some audio quality.")
                }

                Section {
                    Toggle("Enable ReplayGain", isOn: $isReplayGainEnabled)

                    Picker("Mode", selection: $replayGainMode) {
                        ForEach(ReplayGainMode.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isReplayGainEnabled)

                    Toggle("Prevent clipping", isOn: $preventClipping)
                        .disabled(!isReplayGainEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pre-amp")
                            Spacer()
                            Text("\(Int(preAmp.rounded())) dB")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $preAmp, in: gainRange, step: 1)
                    }
                    .disabled(!isReplayGainEnabled)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Default gain")
                            Spacer()
                            Text("\(Int(defaultGain.rounded())) dB")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $defaultGain, in: gainRange, step: 1)
                    }
                    .disabled(!isReplayGainEnabled)
                } header: {
                    Text("ReplayGain")
                } footer: {
                    Text("Adjusts playback volume so tracks and albums sound equally loud, using ReplayGain tags from your library.")
                }

                Section {
                    Toggle("Cache upcoming track", isOn: $isGaplessCacheEnabled)

                    if gaplessCacheRetention != .never {
                        Picker("Cache size limit", selection: $gaplessCacheSizeLimit) {
                            ForEach(GaplessCacheSizeLimit.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(!isGaplessCacheEnabled)
                    }

                    Picker("Keep cached for", selection: retentionSelection) {
                        ForEach(GaplessCacheRetention.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!isGaplessCacheEnabled)
                    .onChange(of: gaplessCacheRetention) { oldValue, newValue in
                        if oldValue == .never, newValue != .never {
                            Task { await EphemeralGaplessCacheService.shared.clearAll() }
                        }
                    }
                    .confirmationDialog(
                        "Delete all cached songs?", isPresented: $showingNeverConfirmation, titleVisibility: .visible
                    ) {
                        Button("Delete Cache and Stop Keeping Songs", role: .destructive) {
                            gaplessCacheRetention = .never
                            Task {
                                await GaplessCacheService.shared.clearAll()
                                await reloadGaplessCacheInfo()
                            }
                        }
                    } message: {
                        Text("Choosing Never deletes every cached song now. From then on, the upcoming track is cached only while it's in the queue.")
                    }

                    Toggle("Convert lossless to ALAC", isOn: $convertLosslessToALAC)
                        .disabled(!isGaplessCacheEnabled)
                    Toggle("Convert Opus to .caf", isOn: $convertOpusToCAF)
                        .disabled(!isGaplessCacheEnabled)

                    if gaplessCacheRetention != .never {
                        DisclosureGroup(isExpanded: $isCachedListExpanded) {
                            if cachedAlbumGroups.isEmpty {
                                Text("No cached songs.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(cachedAlbumGroups) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.title)
                                            .font(.subheadline.weight(.semibold))
                                        ForEach(group.songs) { song in
                                            HStack {
                                                Text(song.title)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(ByteCountFormatter.string(fromByteCount: song.byteSize, countStyle: .file))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } label: {
                            HStack {
                                Text("Currently cached")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: gaplessCacheUsageBytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button("Clear Cache", role: .destructive) {
                            showingClearCacheConfirmation = true
                        }
                        .disabled(cachedRecords.isEmpty)
                    }
                } header: {
                    Text("Gapless Caching")
                } footer: {
                    if gaplessCacheRetention == .never {
                        Text("The upcoming track is cached so it can play gaplessly, and stays cached only while it's in the queue — once it's removed from the queue, it's deleted.")
                    } else {
                        Text("Downloads every track to this device before playing it, instead of streaming, so transitions have no gap even over a transcoded or slow connection. A track not played again within the limit above is automatically removed.")
                    }
                }

                Section {
                    Toggle("Track listening history", isOn: $isScrobblingEnabled)
                        .onChange(of: isScrobblingEnabled) { oldValue, newValue in
                            if oldValue, !newValue {
                                Task { await ScrobbleService.shared.clearAll() }
                            }
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Scrobble after")
                            Spacer()
                            Text("\(Int((scrobbleThreshold * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $scrobbleThreshold, in: 0...1, step: 0.05)
                    }
                    .disabled(!isScrobblingEnabled)

                    Toggle("Scrobble from playlists", isOn: $scrobbleFromPlaylists)
                        .disabled(!isScrobblingEnabled)
                } header: {
                    Text("Listening history")
                } footer: {
                    Text("Reports what you listen to to your server. A song is scrobbled once this much of it has played — 0% as soon as it starts, 100% only if it plays all the way through. When Scrobble from Playlists is off, songs played from a playlist aren't scrobbled. Scrobbles made while offline or while the server is unreachable are sent, in order, as soon as it's available again.")
                }
            }
            .navigationTitle("Playback")
        }
        .toolbar {
        }
        .task {
            await reloadGaplessCacheInfo()
        }
        .confirmationDialog(
            "Delete all cached songs?", isPresented: $showingClearCacheConfirmation, titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await GaplessCacheService.shared.clearAll()
                    await reloadGaplessCacheInfo()
                }
            }
        }
    }

    private func reloadGaplessCacheInfo() async {
        gaplessCacheUsageBytes = await GaplessCacheDatabase.shared.totalBytes()
        cachedRecords = await GaplessCacheDatabase.shared.allRecords()
    }
}

#Preview {
    NavigationStack {
        PlaybackSettingsView()
    }
}
