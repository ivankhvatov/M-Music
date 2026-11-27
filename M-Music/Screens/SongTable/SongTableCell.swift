import UIKit

/// One song's row in `SongTable`: the same artwork, title and artist, download status and menu as
/// `SongRow`, drawn by UIKit with its frames worked out by hand, so that building a row during a
/// fast scroll takes next to no time.
final class SongTableCell: UICollectionViewListCell {
    static let artworkSide = ImageCache.RowArtwork.song

    private enum Metrics {
        static let side: CGFloat = 16
        static let top: CGFloat = 6
        static let spacing: CGFloat = 12
        /// Between the text and the trailing controls: `SongRow`'s spacing on both sides of its
        /// spacer, and the spacer's own least width.
        static let textToControls: CGFloat = 32
        static let titleToArtist: CGFloat = 2
        /// The menu button, around its glyph: the menu opens from it.
        static let menuHeight: CGFloat = 20
    }

    /// What `.secondary` is inside a `List` row's button: the text colour, at half strength.
    static let secondary = UIColor { UIColor.label.resolvedColor(with: $0).withAlphaComponent(0.5) }

    /// The text starts here, and so do the separators.
    static let textLeading = Metrics.side + artworkSide + Metrics.spacing
    static let sideInset = Metrics.side

    /// The menu's items for a song, asked for when the menu is opened.
    var menuElements: ((Child) -> [UIMenuElement])?

    private(set) var track: Child?

    private let content = UIView()
    private let placeholder = UIView()
    private let note = UIImageView(
        image: UIImage(systemName: "music.note", withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
    )
    private let artwork = UIImageView()
    private let title = UILabel()
    private let artist = UILabel()
    private let status = SongTableDownloadStatus()
    private let menuButton = SongMenuButton(type: .custom)
    private weak var badge: UIView?

    private var artworkURL: URL?
    private var artworkImage: UIImage?
    private var loading: Task<Void, Never>?
    private var isAvailable = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        // No highlight or selection colour: a touched row dims, as a plain SwiftUI button does.
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()

        placeholder.backgroundColor = UIColor { Self.secondary.resolvedColor(with: $0).withAlphaComponent(0.075) }
        placeholder.layer.cornerRadius = 4
        note.tintColor = Self.secondary
        note.contentMode = .center
        placeholder.addSubview(note)
        artwork.layer.cornerRadius = 4
        artwork.layer.masksToBounds = true
        artwork.layer.borderWidth = 0.1
        title.font = .preferredFont(forTextStyle: .callout)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        artist.font = .preferredFont(forTextStyle: .caption1)
        artist.adjustsFontForContentSizeCategory = true
        artist.textColor = Self.secondary
        artist.numberOfLines = 0

        let dots = UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        menuButton.setImage(dots, for: .normal)
        // Offline, a song that isn't downloaded: greyed, as a disabled `Menu` is.
        menuButton.setImage(
            dots?.withTintColor(.label.withAlphaComponent(0.25), renderingMode: .alwaysOriginal), for: .disabled
        )
        menuButton.tintColor = .label
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = String(localized: "More")
        // Made when it's opened, for the song the cell shows then — not for every row scrolled by.
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let track = self.track else { return completion([]) }
                completion(self.menuElements?(track) ?? [])
            }
        ])

        [placeholder, artwork, title, artist].forEach(content.addSubview)
        [content, status, menuButton].forEach(contentView.addSubview)
        // The song is one button to VoiceOver, as a `List` row was; the menu is another.
        content.isAccessibilityElement = true
        content.accessibilityTraits = .button
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: SongTableCell, _) in
            cell.updateBorder()
        }
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    private func updateBorder() {
        artwork.layer.borderColor = Self.secondary.resolvedColor(with: traitCollection).cgColor
    }

    // MARK: - Content

    /// Cheap when nothing has changed, as when a cell that was prepared ahead comes on screen.
    func show(_ track: Child, artworkURL url: URL?, isAvailable: Bool, download: DownloadState) {
        if track != self.track {
            self.track = track
            title.text = track.title
            artist.text = track.artist
            artist.isHidden = track.artist == nil
            content.accessibilityLabel = [track.title, track.artist].compactMap { $0 }.joined(separator: ", ")
            setNeedsLayout()
        }
        if status.show(download) { setNeedsLayout() }
        let availabilityChanged = isAvailable != self.isAvailable
        self.isAvailable = isAvailable
        // As a disabled row of a `List` was drawn: dimmed twice over, the artist's line in the
        // title's colour.
        content.alpha = isAvailable ? 1 : 0.2
        artist.textColor = isAvailable ? Self.secondary : .label
        menuButton.isEnabled = isAvailable
        content.accessibilityTraits = isAvailable ? .button : [.button, .notEnabled]
        if url != artworkURL || (artworkImage == nil && loading == nil) {
            load(url)
        } else if availabilityChanged {
            showArtwork(artworkImage)
        }
    }

    private func load(_ url: URL?) {
        loading?.cancel()
        loading = nil
        artworkURL = url
        let cached = url.flatMap { ImageCache.shared.image(for: $0) }
        showArtwork(cached)
        guard cached == nil, let url else { return }
        loading = Task { @MainActor [weak self] in
            let image = await ImageCache.shared.load(url)
            guard !Task.isCancelled, let self, self.artworkURL == url else { return }
            self.loading = nil
            guard let image else { return }
            self.showArtwork(image)
        }
    }

    private func showArtwork(_ image: UIImage?) {
        artworkImage = image
        // Offline and not downloaded: muted, as `dimmedIfUnavailable` draws it.
        artwork.image = isAvailable ? image : image?.muted()
        artwork.isHidden = image == nil
        placeholder.isHidden = image != nil
        setNeedsLayout()
    }

    /// The view marking the song that's playing, over the artwork — or none.
    func showBadge(_ view: UIView?) {
        if let badge, badge !== view, badge.superview === contentView { badge.removeFromSuperview() }
        badge = view
        guard let view else { return }
        if view.superview !== contentView { contentView.addSubview(view) }
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        artworkURL = nil
        artworkImage = nil
        showBadge(nil)
        track = nil
    }

    /// A held row dims as a plain SwiftUI button does.
    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted && isAvailable ? 0.75 : 1 }
    }

    // MARK: - Layout

    private struct TextLayout {
        let width: CGFloat
        let titleHeight: CGFloat
        let artistHeight: CGFloat
        var height: CGFloat { titleHeight + (artistHeight > 0 ? Metrics.titleToArtist + artistHeight : 0) }
    }

    private var menuGlyphWidth: CGFloat { ceil(menuButton.image(for: .normal)?.size.width ?? 22) }

    /// Where the trailing controls start, for a row `width` wide.
    private func controlsLeading(in width: CGFloat) -> CGFloat {
        let menu = width - Metrics.side - menuGlyphWidth
        return status.isShowing ? menu - Metrics.spacing - status.side : menu
    }

    private func textLayout(in width: CGFloat) -> TextLayout {
        let textWidth = max(0, controlsLeading(in: width) - Metrics.textToControls - Self.textLeading)
        let fitting = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        return TextLayout(
            width: textWidth,
            titleHeight: title.sizeThatFits(fitting).height,
            artistHeight: artist.isHidden ? 0 : artist.sizeThatFits(fitting).height
        )
    }

    private func rowHeight(in width: CGFloat) -> CGFloat {
        max(Self.artworkSide, ceil(textLayout(in: width).height)) + 2 * Metrics.top
    }

    override func preferredLayoutAttributesFitting(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let result = attributes.copy() as? UICollectionViewLayoutAttributes ?? attributes
        result.size.height = rowHeight(in: attributes.size.width)
        return result
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        content.frame = bounds
        let side = Self.artworkSide
        let artworkFrame = CGRect(x: Metrics.side, y: pixel((bounds.height - side) / 2), width: side, height: side)
        placeholder.frame = artworkFrame
        note.frame = placeholder.bounds
        // The picture keeps its own shape (its longer side filling the square), and the rounded
        // corners and outline follow it.
        if let size = artworkImage?.size, size.width > 0, size.height > 0 {
            let ratio = min(side / size.width, side / size.height)
            let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
            artwork.frame = CGRect(
                x: artworkFrame.midX - fitted.width / 2, y: artworkFrame.midY - fitted.height / 2,
                width: fitted.width, height: fitted.height
            )
        } else {
            artwork.frame = artworkFrame
        }
        badge?.frame = artworkFrame

        let text = textLayout(in: bounds.width)
        // On whole pixels, as `List` put it: a block no taller than the artwork on the one below.
        let centred = (bounds.height - text.height) / 2
        let scale = max(traitCollection.displayScale, 1)
        let top = text.height < side ? (centred * scale).rounded(.up) / scale : pixel(centred)
        title.frame = CGRect(x: Self.textLeading, y: top, width: text.width, height: text.titleHeight)
        artist.frame = CGRect(
            x: Self.textLeading, y: top + text.titleHeight + Metrics.titleToArtist,
            width: text.width, height: text.artistHeight
        )

        menuButton.frame = CGRect(
            x: bounds.width - Metrics.side - menuGlyphWidth, y: pixel((bounds.height - Metrics.menuHeight) / 2),
            width: menuGlyphWidth, height: Metrics.menuHeight
        )
        status.frame = CGRect(
            x: controlsLeading(in: bounds.width), y: pixel((bounds.height - status.side) / 2),
            width: status.side, height: status.side
        )
    }

    /// `value` on a whole pixel.
    private func pixel(_ value: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (value * scale).rounded() / scale
    }
}

private extension UIImage {
    /// With most of its colour taken out: the look of artwork that isn't available offline.
    func muted() -> UIImage {
        guard let source = CIImage(image: self) else { return self }
        let filtered = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.3])
        guard let result = CIContext.muting.createCGImage(filtered, from: filtered.extent) else { return self }
        return UIImage(cgImage: result, scale: scale, orientation: imageOrientation)
    }
}

private extension CIContext {
    nonisolated(unsafe) static let muting = CIContext()
}

/// A button as small as its glyph that is easy to touch all the same.
private final class SongMenuButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -11, dy: -12).contains(point)
    }
}

/// `DownloadStatusIndicator` in UIKit: a filled glyph once a song is downloaded, a ring while it
/// is on its way.
final class SongTableDownloadStatus: UIView {
    private let glyph = UIImageView(
        image: UIImage(
            systemName: "arrow.down.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)
        )
    )
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private(set) var isShowing = false
    private var isRing = false
    private var shown: DownloadState?

    /// How wide and tall it is.
    var side: CGFloat { isRing ? 12 : ceil(glyph.image?.size.width ?? 14) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        glyph.tintColor = SongTableCell.secondary
        glyph.contentMode = .center
        addSubview(glyph)
        for ring in [track, progress] {
            ring.fillColor = nil
            ring.lineWidth = 2
            // From twelve o'clock, clockwise.
            ring.path = UIBezierPath(
                arcCenter: CGPoint(x: 6, y: 6), radius: 6, startAngle: -.pi / 2, endAngle: 3 * .pi / 2, clockwise: true
            ).cgPath
            layer.addSublayer(ring)
        }
        progress.lineCap = .round
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SongTableDownloadStatus, _) in
            view.updateColors()
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    private func updateColors() {
        let secondary = SongTableCell.secondary.resolvedColor(with: traitCollection)
        track.strokeColor = secondary.withAlphaComponent(secondary.cgColor.alpha * 0.25).cgColor
        progress.strokeColor = secondary.cgColor
    }

    /// Returns whether what's shown has changed.
    func show(_ state: DownloadState) -> Bool {
        guard state != shown else { return false }
        shown = state
        let fraction: Double?
        switch state {
        case .completed: fraction = nil
        case .queued: fraction = 0
        case .downloading(let value): fraction = value
        case .none, .failed:
            isShowing = false
            isHidden = true
            return true
        }
        isShowing = true
        isHidden = false
        isRing = fraction != nil
        glyph.isHidden = isRing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.isHidden = !isRing
        progress.isHidden = !isRing
        // A stub stays visible even at nothing, so "queued" doesn't look like nothing at all.
        progress.strokeEnd = max(0.03, min(fraction ?? 0, 1))
        CATransaction.commit()
        setNeedsLayout()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
    }
}
