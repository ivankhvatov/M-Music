import Combine
import SwiftUI
import UIKit

/// The Songs screen's list, as a `UICollectionView`.
///
/// SwiftUI's `List` built each row too slowly for a fast scroll through a few thousand songs: in
/// measurements the screen stalled for about a third of the time while flinging, however much the
/// rows were pared down. UIKit reuses cells and the stalls are gone. It looks and behaves as the
/// `List` did: the same rows (`SongTableCell`), separators and menus, pull to refresh, the play and
/// shuffle buttons on top, and covers warmed ahead of the scroll.
struct SongTable<Header: View>: UIViewControllerRepresentable {
    let songs: [Child]
    @ViewBuilder let header: () -> Header
    /// The row at this index came on screen.
    let onRowAppear: (Int) -> Void
    let onSelect: (Child) -> Void
    let onRefresh: () async -> Void
    /// "Add to playlist" was chosen: the screen shows the sheet.
    let onAddToPlaylist: (Child) -> Void

    func makeUIViewController(context: Context) -> SongTableController {
        SongTableController()
    }

    func updateUIViewController(_ controller: SongTableController, context: Context) {
        controller.onRowAppear = onRowAppear
        controller.onSelect = onSelect
        controller.onRefresh = onRefresh
        controller.onAddToPlaylist = onAddToPlaylist
        controller.show(songs, header: AnyView(header()), displayScale: context.environment.displayScale)
    }
}

/// What lies over the artwork of the song that's playing, as in `SongRow`.
private struct SongPlayingBadge: View {
    @ObservedObject private var player = PlayerManager.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(0.45))
            PlayingIndicator(isPlaying: player.isPlaying, color: .white)
        }
        .frame(width: SongTableCell.artworkSide, height: SongTableCell.artworkSide)
    }
}

/// A `UICollectionViewController`, which keeps its content clear of the keyboard by itself.
final class SongTableController: UICollectionViewController {
    var onRowAppear: (Int) -> Void = { _ in }
    var onSelect: (Child) -> Void = { _ in }
    var onRefresh: () async -> Void = {}
    var onAddToPlaylist: (Child) -> Void = { _ in }

    private var songs: [Child] = []
    private var header = AnyView(EmptyView())
    private var displayScale: CGFloat = 3
    private var subscriptions: Set<AnyCancellable> = []

    /// One view for the playing song's row, moved to whichever cell shows it.
    private lazy var badge: UIHostingController<SongPlayingBadge> = {
        let hosting = UIHostingController(rootView: SongPlayingBadge())
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        hosting.safeAreaRegions = []
        addChild(hosting)
        hosting.didMove(toParent: self)
        return hosting
    }()

    private lazy var headerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.contentConfiguration = UIHostingConfiguration { self.header }
            .margins(.horizontal, SongTableCell.sideInset)
            .margins(.vertical, 8)
        cell.automaticallyUpdatesBackgroundConfiguration = false
        cell.backgroundConfiguration = .clear()
    }

    private lazy var songRegistration = UICollectionView.CellRegistration<SongTableCell, Int> {
        [weak self] cell, _, index in
        self?.configure(cell, at: index)
    }

    init() {
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
            configuration.itemSeparatorHandler = { indexPath, separator in
                var separator = separator
                separator.topSeparatorVisibility = .hidden
                // The first item is the buttons, which have no line under them.
                separator.bottomSeparatorVisibility = indexPath.item == 0 ? .hidden : .visible
                separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(
                    top: 0, leading: SongTableCell.textLeading, bottom: 0, trailing: SongTableCell.sideInset
                )
                return separator
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Registrations have to exist before the first cell is asked for.
        _ = (headerRegistration, songRegistration)
        collectionView.backgroundColor = .systemBackground
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            Task { @MainActor in
                await self?.onRefresh()
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: SongTableController, _) in
            controller.collectionView.reloadData()
        }
        watchForChanges()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ScrollState.shared.set(scrolling: false)
    }

    func show(_ songs: [Child], header: AnyView, displayScale: CGFloat) {
        loadViewIfNeeded()
        self.header = header
        guard songs != self.songs || displayScale != self.displayScale else {
            // The buttons act on what the screen lists now.
            if let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? UICollectionViewListCell {
                cell.contentConfiguration = UIHostingConfiguration { header }
                    .margins(.horizontal, SongTableCell.sideInset)
                    .margins(.vertical, 8)
            }
            return
        }
        self.songs = songs
        self.displayScale = displayScale
        collectionView.reloadData()
    }

    // MARK: - Rows

    private func isAvailable(_ track: Child) -> Bool {
        NetworkMonitor.shared.isOnline || DownloadStore.shared.isDownloaded(track.id.raw)
    }

    private func configure(_ cell: SongTableCell, at index: Int) {
        guard songs.indices.contains(index) else { return }
        let track = songs[index]
        cell.menuElements = { [weak self] in self?.menuElements(for: $0) ?? [] }
        cell.show(
            track,
            artworkURL: ArtworkRequest.songRow(ListArtwork.shared.artworkId(for: track), scale: displayScale).url,
            isAvailable: isAvailable(track),
            download: DownloadStore.shared.state(for: track.id.raw)
        )
        showBadge(in: cell)
    }

    private func showBadge(in cell: SongTableCell) {
        let isPlaying = cell.track.map { $0.id == PlayerManager.shared.currentTrack?.id } ?? false
        cell.showBadge(isPlaying ? badge.view : nil)
    }

    private var songCells: [SongTableCell] { collectionView.visibleCells.compactMap { $0 as? SongTableCell } }

    private func refreshVisibleRows() {
        for cell in songCells {
            guard let path = collectionView.indexPath(for: cell) else { continue }
            let height = cell.bounds.height
            configure(cell, at: path.item - 1)
            // A download's mark narrows the text, which may then need another line.
            let wanted = cell.preferredLayoutAttributesFitting(
                collectionView.layoutAttributesForItem(at: path) ?? UICollectionViewLayoutAttributes(forCellWith: path)
            ).size.height
            if abs(wanted - height) > 0.5 { cell.invalidateIntrinsicContentSize() }
        }
    }

    /// What can change a row that's on screen. Each of these publishes before the value changes,
    /// so the rows are read a turn later.
    private func watchForChanges() {
        NetworkMonitor.shared.$isOnline.removeDuplicates().dropFirst().map { _ in () }
            .merge(with: DownloadStore.shared.objectWillChange.map { _ in () })
            .merge(with: DownloadProgressStore.shared.objectWillChange.map { _ in () })
            .merge(with: NotificationCenter.default.publisher(for: ListArtwork.didChange).map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshVisibleRows() }
            .store(in: &subscriptions)
        PlayerManager.shared.$currentIndex.map { _ in () }
            .merge(with: PlayerManager.shared.$queue.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                for cell in songCells { showBadge(in: cell) }
            }
            .store(in: &subscriptions)
    }

    // MARK: - The song menu

    /// `SongRow`'s menu, with the songs list's items.
    private func menuElements(for track: Child) -> [UIMenuElement] {
        func action(
            _ title: String, _ symbol: String, attributes: UIMenuElement.Attributes = [],
            _ handler: @escaping () -> Void
        ) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: attributes) { _ in handler() }
        }
        let player = PlayerManager.shared
        let downloads = DownloadStore.shared
        let starred = StarStore.shared.isStarred(track)
        var items: [UIMenuElement] = [
            action(
                starred ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                starred ? "star.slash.fill" : "star.fill"
            ) { StarStore.shared.toggleStarred(track) },
            action(String(localized: "Play next"), "text.line.first.and.arrowtriangle.forward") {
                player.playNext(track)
            },
            action(String(localized: "Add to queue"), "text.line.last.and.arrowtriangle.forward") {
                player.addToQueue(track)
            },
            action(String(localized: "Add to playlist"), "text.badge.plus") { [weak self] in
                self?.onAddToPlaylist(track)
            },
        ]
        if let albumID = track.albumId?.raw {
            items.append(action(String(localized: "Go to album"), "opticaldisc") {
                AppNavigation.shared.open(.album(id: albumID), fromPlayer: false)
            })
        }
        // The song's own artist; the album's, for a song that doesn't name one.
        let artistRoute: AppRoute? = track.artistId.map { .artistWithID($0.raw) }
            ?? track.albumId.map { .artist(ofAlbum: $0.raw) }
        if let artistRoute {
            items.append(action(String(localized: "Go to artist"), AppRoute.artistSymbol) {
                AppNavigation.shared.open(artistRoute, fromPlayer: false)
            })
        }
        switch downloads.state(for: track.id.raw) {
        case .completed:
            items.append(action(String(localized: "Remove Download"), "checkmark.circle.fill", attributes: .destructive) {
                downloads.remove(songId: track.id.raw)
            })
        case .queued, .downloading:
            items.append(action(String(localized: "Downloading…"), "arrow.down.circle", attributes: .disabled) {})
        case .none, .failed:
            items.append(action(String(localized: "Download"), "arrow.down.circle") { downloads.download(track) })
        }
        return items
    }

    // MARK: - UICollectionViewDataSource and delegate

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        songs.isEmpty ? 0 : songs.count + 1
    }

    override func collectionView(
        _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        indexPath.item == 0
            ? collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: 0)
            : collectionView.dequeueConfiguredReusableCell(
                using: songRegistration, for: indexPath, item: indexPath.item - 1
            )
    }

    override func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard indexPath.item > 0 else { return }
        // Prepared ahead, so it may have missed a change made since.
        if let cell = cell as? SongTableCell { configure(cell, at: indexPath.item - 1) }
        onRowAppear(indexPath.item - 1)
    }

    override func collectionView(
        _ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath
    ) -> Bool {
        // Offline, a song that isn't downloaded can't be played.
        indexPath.item > 0 && songs.indices.contains(indexPath.item - 1) && isAvailable(songs[indexPath.item - 1])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard songs.indices.contains(indexPath.item - 1) else { return }
        onSelect(songs[indexPath.item - 1])
    }

    // MARK: - Scrolling

    /// What's loaded behind the scroll waits for it to stop — see `ScrollActivity`.
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        ScrollState.shared.set(scrolling: true)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { ScrollState.shared.set(scrolling: false) }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        ScrollState.shared.set(scrolling: false)
    }

    override func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        ScrollState.shared.set(scrolling: false)
    }
}
