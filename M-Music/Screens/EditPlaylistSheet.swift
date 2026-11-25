import SwiftUI
import PhotosUI

/// The sheet behind the pencil in a playlist's header: its artwork (upload one of your own, or
/// delete it), its name, and its songs, which can be put in a different order. Nothing is sent to
/// the server until "Save"; "Cancel" drops the changes.
struct EditPlaylistSheet: View {
    let playlist: PlaylistSummary
    let artworkURL: URL?
    /// Called with the playlist as the server has it after the changes were saved.
    let onSaved: (PlaylistWithSongs) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// A song of the playlist as one row of the sheet. A playlist can hold a song more than once,
    /// so a row is told apart by its own id rather than the song's.
    private struct Entry: Identifiable {
        let id = UUID()
        let song: Child
    }

    @State private var name: String
    @State private var entries: [Entry]
    private let originalSongIds: [String]

    /// Whether the server has artwork the user uploaded for the playlist — read when the sheet
    /// opens; the delete button is there only if so.
    @State private var hasUploadedArtwork = false
    @State private var pickerItem: PhotosPickerItem?
    /// The image picked to be the artwork, and the JPEG that is uploaded for it.
    @State private var pickedImage: UIImage?
    @State private var pickedData: Data?
    /// The uploaded artwork is to be deleted when saving.
    @State private var removesArtwork = false
    @State private var showingDeleteArtworkConfirmation = false

    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        playlist: PlaylistSummary,
        songs: [Child],
        artworkURL: URL?,
        onSaved: @escaping (PlaylistWithSongs) -> Void
    ) {
        self.playlist = playlist
        self.artworkURL = artworkURL
        self.onSaved = onSaved
        _name = State(initialValue: playlist.name)
        _entries = State(initialValue: songs.map { Entry(song: $0) })
        originalSongIds = songs.map(\.id.raw)
    }

    private let rowArtworkSize: CGFloat = ImageCache.RowArtwork.song
    private let artworkSize: CGFloat = 240

    // MARK: - Changes

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmedName != playlist.name }
    private var orderChanged: Bool { entries.map(\.song.id.raw) != originalSongIds }
    private var hasChanges: Bool { nameChanged || orderChanged || pickedData != nil || removesArtwork }
    private var canSave: Bool { hasChanges && !trimmedName.isEmpty && !isSaving }

    /// There is artwork of the user's to delete: one picked here, or one uploaded earlier that
    /// isn't already going to be deleted.
    private var showsDeleteArtwork: Bool {
        pickedData != nil || (hasUploadedArtwork && !removesArtwork)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                artworkRow
                nameRow

                Section {
                    ForEach(entries) { entry in
                        SongRow(
                            track: entry.song,
                            rowArtworkSize: rowArtworkSize,
                            displayScale: displayScale,
                            showsPlayingIndicator: false,
                            showsTrailingActions: false
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                    .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Songs")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
            // Always editing: that is what shows each row's handle for dragging it.
            .environment(\.editMode, .constant(.active))
            .scrollDismissesKeyboard(.interactively)
            .disabled(isSaving)
            .navigationTitle("Edit Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .confirmationDialog(
                "Delete the artwork?",
                isPresented: $showingDeleteArtworkConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteArtwork() }
            } message: {
                Text("The playlist goes back to the artwork Navidrome makes from its songs.")
            }
            .alert("Couldn't save the playlist", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSaving)
        .task {
            hasUploadedArtwork = (try? await NavidromeNativeAPI.shared.hasUploadedArtwork(playlistId: playlist.id.raw)) ?? false
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
    }

    // MARK: - Artwork

    private var artworkRow: some View {
        HStack {
            Spacer()
            artworkImage
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary, lineWidth: 0.15)
                )
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        if showsDeleteArtwork {
                            Button {
                                showingDeleteArtworkConfirmation = true
                            } label: {
                                artworkButtonLabel("trash")
                            }
                            .accessibilityLabel("Delete the artwork")
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            artworkButtonLabel("pencil")
                        }
                        .accessibilityLabel("Choose an artwork")
                    }
                    .padding(8)
                }
                .shadow(color: .black.opacity(0.5), radius: 20)
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    private func artworkButtonLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var artworkImage: some View {
        if let pickedImage {
            Image(uiImage: pickedImage)
                .resizable()
                .scaledToFill()
        } else if removesArtwork {
            // What Navidrome will make isn't known until it has; the server draws it from the songs.
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                }
        } else {
            CachedAsyncImage(url: artworkURL, fallbackMaxPixelSize: ImageCache.cardMaxPixelSize) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
            }
        }
    }

    /// Reads the picked photo and makes the JPEG that is uploaded for it: scaled down to a size
    /// that is plenty for artwork, and in a format the server reads whatever the photo was (HEIC,
    /// say).
    private func loadPicked(_ item: PhotosPickerItem) async {
        defer { pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = String(localized: "The image couldn't be read.")
            return
        }
        let prepared = await Task.detached(priority: .userInitiated) { Self.preparedArtwork(from: data) }.value
        guard let prepared else {
            errorMessage = String(localized: "The image couldn't be read.")
            return
        }
        pickedImage = prepared.image
        pickedData = prepared.jpeg
        removesArtwork = false
    }

    private nonisolated static func preparedArtwork(from data: Data, maxSide: CGFloat = 1600) -> (image: UIImage, jpeg: Data)? {
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (image, jpeg)
    }

    /// Takes the artwork out of this edit: a picked image is dropped, and the uploaded one, if the
    /// server has it, is deleted when saving.
    private func deleteArtwork() {
        pickedImage = nil
        pickedData = nil
        removesArtwork = hasUploadedArtwork
    }

    // MARK: - Name

    private var nameRow: some View {
        TextField("Playlist name", text: $name)
            .font(.title3.weight(.semibold))
            .submitLabel(.done)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            .listRowSeparator(.hidden)
    }

    // MARK: - Saving

    private func save() {
        guard canSave else { return }
        isSaving = true
        let artwork: PlaylistEditor.ArtworkChange = if let pickedData {
            .upload(pickedData)
        } else if removesArtwork {
            .remove
        } else {
            .keep
        }
        let newName = nameChanged ? trimmedName : nil
        let songIds = orderChanged ? entries.map(\.song.id.raw) : nil
        Task {
            defer { isSaving = false }
            do {
                let saved = try await PlaylistEditor.save(playlist, name: newName, songIds: songIds, artwork: artwork)
                if let saved { onSaved(saved) }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                // Part of it may have gone through before the failure: show that.
                if let current = try? await PlaylistEditor.refresh(playlist) { onSaved(current) }
            }
        }
    }
}

extension PlaylistEditor {
    /// What to do with a playlist's uploaded artwork.
    enum ArtworkChange {
        case keep
        case remove
        case upload(Data)
    }

    /// Sends the changes — a new name, the songs in a new order, new or no artwork — to the server,
    /// then reads the playlist back and writes it over what's cached of it. `nil` for what stays
    /// as it is. The result is `nil` when the changes went through but the playlist couldn't be
    /// read back after them.
    @MainActor
    static func save(
        _ playlist: PlaylistSummary,
        name: String?,
        songIds: [String]?,
        artwork: ArtworkChange
    ) async throws -> PlaylistWithSongs? {
        let client = SubsonicClient.shared
        if let name {
            try await client.updatePlaylist(playlistId: playlist.id.raw, name: name)
        }
        if let songIds {
            // Replaces the songs by the same ones in the new order; the playlist keeps its name.
            try await client.replacePlaylist(playlistId: playlist.id.raw, songIds: songIds)
        }
        switch artwork {
        case .keep:
            break
        case .remove:
            try await NavidromeNativeAPI.shared.removeArtwork(playlistId: playlist.id.raw)
        case .upload(let data):
            try await NavidromeNativeAPI.shared.uploadArtwork(playlistId: playlist.id.raw, imageData: data)
        }
        return try? await refresh(playlist)
    }
}
