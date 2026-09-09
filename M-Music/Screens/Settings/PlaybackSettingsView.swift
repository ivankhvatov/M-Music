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

    @AppStorage(DownloadTranscodingSettings.Keys.isEnabled) private var isDownloadTranscodingEnabled = false
    @AppStorage(DownloadTranscodingSettings.Keys.format) private var downloadFormat = TranscodingFormat.mp3
    @AppStorage(DownloadTranscodingSettings.Keys.bitrate) private var downloadBitrate = TranscodingBitrate.k192

    private let gainRange: ClosedRange<Double> = -15...15

    var body: some View {
        NavigationStack {
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
                    } header: {
                        Text("Downloads")
                    } footer: {
                        Text("Applies only to new downloads — songs already saved to this device keep whatever quality they were downloaded at.")
                    }
                }
                .navigationTitle("Playback")
            }
            .toolbar {
            }
        }
    }
}

#Preview {
    PlaybackSettingsView()
}
