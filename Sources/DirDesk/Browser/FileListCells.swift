import AppKit
import DirDeskCore

/// Shared cloud state rendering for list rows, columns and icon/gallery thumbnails.
final class CloudStatusBadgeView: NSImageView {
    private var statusText: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        symbolConfiguration = .init(pointSize: 12, weight: .regular)
        configure(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ status: FileCloudStatus?) {
        // Clear every presentation attribute when a cell is reused for a non-cloud item.
        image = nil
        contentTintColor = nil
        toolTip = nil
        statusText = nil
        setAccessibilityLabel(nil)
        setAccessibilityElement(false)
        isHidden = true
        guard let status else { return }

        let symbol: String
        let color: NSColor
        let title: String
        switch status {
        case .local:
            symbol = "cloud"
            color = .secondaryLabelColor
            title = L("Available Locally")
        case .synchronized:
            symbol = "icloud"
            color = .systemGreen
            title = L("Synchronized")
        case .cloudOnly:
            symbol = "icloud.and.arrow.down"
            color = .secondaryLabelColor
            title = L("Not Downloaded")
        case .downloading:
            symbol = "icloud.and.arrow.down"
            color = .systemBlue
            title = L("Downloading")
        case .uploading:
            symbol = "icloud.and.arrow.up"
            color = .systemBlue
            title = L("Uploading")
        case .failed:
            symbol = "exclamationmark.icloud"
            color = .systemOrange
            title = L("Sync Failed")
        }
        image = status == .synchronized ? Self.synchronizedImage
            : NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        contentTintColor = color
        toolTip = title
        statusText = title
        setAccessibilityLabel(title)
        setAccessibilityElement(true)
        isHidden = false
    }

    func accessibilityLabel(forFileName name: String) -> String {
        statusText.map { name + ", " + $0 } ?? name
    }

    /// SF Symbols has no cloud.checkmark on some supported systems. Keep the check inside the cloud outline.
    private static let synchronizedImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            let cloud = NSBezierPath()
            cloud.lineWidth = 1.2
            cloud.lineCapStyle = .round
            cloud.lineJoinStyle = .round
            cloud.move(to: NSPoint(x: 4.3, y: 2.5))
            cloud.curve(to: NSPoint(x: 3.7, y: 9), controlPoint1: NSPoint(x: 0.1, y: 2.5), controlPoint2: NSPoint(x: 0.1, y: 8.8))
            cloud.curve(to: NSPoint(x: 12.9, y: 9.8), controlPoint1: NSPoint(x: 4.5, y: 14), controlPoint2: NSPoint(x: 11.9, y: 14))
            cloud.curve(to: NSPoint(x: 13.8, y: 2.5), controlPoint1: NSPoint(x: 18.2, y: 10.2), controlPoint2: NSPoint(x: 18.6, y: 2.5))
            cloud.close()
            cloud.stroke()
            let check = NSBezierPath()
            check.lineWidth = 1.4
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: 6, y: 6.8))
            check.line(to: NSPoint(x: 8.2, y: 4.8))
            check.line(to: NSPoint(x: 11.9, y: 8.8))
            check.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Name column cell: indentation, inline disclosure chevron, icon or thumbnail, name.
/// A Git repository folder carries an orange badge on the lower right of its icon, as in the original. Like the
/// original, file rows carry no per-file Git state (its `GitRepositoryStatus` only holds counts, and the reference
/// capture of a repository shows plain rows); the counts appear in the inspector.
final class FileNameCellView: NSTableCellView {
    let disclosure = NSButton()
    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let badgeView = NSImageView()
    let tagDots = TagDotsView()
    let gitBadge = GitBadgeView()
    let cloudBadge = CloudStatusBadgeView()
    private var cloudWidth: NSLayoutConstraint!
    private var leadingConstraint: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    var onToggle: (() -> Void)?
    private(set) var representedPath: String?
    var assetRevision: UInt64 = 0
    var hasContentThumbnail = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // A thin grey chevron (› collapsed, ⌄ expanded), 6.5 × 11 pt in the original's captures.
        disclosure.isBordered = false
        disclosure.setButtonType(.momentaryChange)
        disclosure.title = ""
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.cell?.truncatesLastVisibleLine = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.image = Self.gitBadgeImage
        badgeView.setAccessibilityLabel(L("Git Repository"))
        badgeView.isHidden = true
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        gitBadge.translatesAutoresizingMaskIntoConstraints = false
        cloudBadge.translatesAutoresizingMaskIntoConstraints = false
        [disclosure, iconView, nameField, badgeView, tagDots, gitBadge, cloudBadge].forEach(addSubview)
        textField = nameField
        imageView = iconView
        leadingConstraint = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.baseIndent)
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            leadingConstraint,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 13),
            iconView.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight,
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 0.5),
            badgeView.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 0.5),
            badgeView.widthAnchor.constraint(equalToConstant: 9),
            badgeView.heightAnchor.constraint(equalToConstant: 9),
            tagDots.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 4),
            tagDots.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadge.leadingAnchor.constraint(equalTo: tagDots.trailingAnchor, constant: 4),
            gitBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.leadingAnchor.constraint(greaterThanOrEqualTo: gitBadge.trailingAnchor, constant: 4),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            cloudBadge.heightAnchor.constraint(equalToConstant: 14),
        ])
        cloudWidth = cloudBadge.widthAnchor.constraint(equalToConstant: 0)
        cloudWidth.isActive = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    /// Leading inset of a top-level row and the indentation per outline level (13 pt in the original).
    static let baseIndent: CGFloat = 3
    static let levelIndent: CGFloat = 13

    private static let chevronConfiguration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)
    private static let collapsedChevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(chevronConfiguration)
    private static let expandedChevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(chevronConfiguration)

    /// Orange rounded square with a white branch mark, drawn on the lower right of a repository's folder icon.
    static let gitBadgeImage: NSImage = {
        let image = NSImage(size: NSSize(width: 9, height: 9), flipped: false) { rect in
            NSColor(srgbRed: 0.98, green: 0.58, blue: 0.20, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2.2, yRadius: 2.2).fill()
            let mark = NSBezierPath()
            mark.lineWidth = 1.1
            mark.lineCapStyle = .round
            mark.move(to: NSPoint(x: 3.1, y: 7.1))
            mark.line(to: NSPoint(x: 3.1, y: 1.9))
            mark.move(to: NSPoint(x: 6.2, y: 7.1))
            mark.curve(to: NSPoint(x: 3.2, y: 3.4), controlPoint1: NSPoint(x: 6.2, y: 4.6), controlPoint2: NSPoint(x: 4.6, y: 3.6))
            NSColor.white.setStroke()
            mark.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }()

    func configure(item: FileItem, depth: Int, expanded: Bool, iconSize: CGFloat, image: NSImage, isGitRepository: Bool,
                   tagColors: [NSColor], truncation: NSLineBreakMode, gitStates: Set<GitFileState> = []) {
        gitBadge.states = gitStates
        representedPath = item.url.path
        leadingConstraint.constant = Self.baseIndent + CGFloat(depth) * Self.levelIndent
        disclosure.isHidden = !item.isBrowsableFolder
        disclosure.image = expanded ? Self.expandedChevron : Self.collapsedChevron
        disclosure.setAccessibilityLabel((expanded ? L("Collapse Folder") : L("Expand Folder")) + ": " + item.name)
        iconWidth.constant = iconSize
        iconHeight.constant = iconSize
        iconView.image = image
        nameField.stringValue = item.name
        nameField.lineBreakMode = truncation
        nameField.textColor = .labelColor
        badgeView.isHidden = !isGitRepository
        tagDots.colors = tagColors
        updateCloudStatus(item.cloudStatus, name: item.name)
    }

    func updateCloudStatus(_ status: FileCloudStatus?, name: String) {
        cloudBadge.configure(status)
        cloudWidth.constant = status == nil ? 0 : 18
        setAccessibilityLabel(cloudBadge.accessibilityLabel(forFileName: name))
    }
}

/// Git state marks after a name: staged (green), unstaged (orange), untracked (gray), conflict (red).
final class GitBadgeView: NSView {
    var states: Set<GitFileState> = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
            toolTip = states.sorted().map(Self.title).joined(separator: ", ")
            setAccessibilityLabel(toolTip)
        }
    }

    static func color(_ state: GitFileState) -> NSColor {
        switch state {
        case .staged: .systemBlue
        case .unstaged: .systemOrange
        case .untracked: .systemGray
        case .conflict: .systemRed
        }
    }

    static func title(_ state: GitFileState) -> String {
        switch state {
        case .staged: L("Staged")
        case .unstaged: L("Unstaged")
        case .untracked: L("Untracked")
        case .conflict: L("Conflict")
        }
    }

    override var intrinsicContentSize: NSSize {
        states.isEmpty ? .zero : NSSize(width: CGFloat(states.count) * 9 - 2, height: 7)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, state) in states.sorted().enumerated() {
            Self.color(state).setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * 9, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
        }
    }
}

/// Small overlapping Finder-tag color dots after a name.
final class TagDotsView: NSView {
    var colors: [NSColor] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        colors.isEmpty ? .zero : NSSize(width: 8 + CGFloat(colors.count - 1) * 5, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, color) in colors.enumerated() {
            let rect = NSRect(x: CGFloat(index) * 5, y: (bounds.height - 8) / 2, width: 8, height: 8)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.windowBackgroundColor.setStroke()
            let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
    }
}

/// Row background for the list: full-width stripes on odd rows and an inset rounded selection that joins
/// neighbouring selected rows, matching the original's list.
final class FileTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("FileTableRow")
    var striped = false { didSet { if striped != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        guard striped else { return }
        (effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.035)).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 10, dy: 0)
        let radius: CGFloat = 5
        let path = NSBezierPath()
        let topSquare = isPreviousRowSelected, bottomSquare = isNextRowSelected
        // Flipped view: minY is the top edge.
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.minY), radius: topSquare ? 0 : radius)
        path.appendArc(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.midY), radius: topSquare ? 0 : radius)
        path.appendArc(from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.midX, y: rect.maxY), radius: bottomSquare ? 0 : radius)
        path.appendArc(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.midY), radius: bottomSquare ? 0 : radius)
        path.close()
        // The system's unemphasized colour nearly matches the dark list background, so inactive selections use a
        // stronger neutral overlay.
        let inactive = effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)
        (isEmphasized ? NSColor.selectedContentBackgroundColor : inactive).setFill()
        path.fill()
    }
}

/// Date cell that draws the text inside a soft rounded pill tinted by the date's age.
final class FileDateCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    var pillColor: NSColor? { didSet { needsDisplay = true } }
    private var customTextColor: NSColor?

    /// On an emphasized selection the pill is dropped and the text turns white, as in the original.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : (customTextColor ?? .labelColor)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, background: NSColor?, textColor: NSColor?) {
        label.stringValue = text
        customTextColor = textColor
        label.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : (textColor ?? .labelColor)
        pillColor = background
        setAccessibilityLabel(text)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pillColor, backgroundStyle != .emphasized, !label.stringValue.isEmpty else { return }
        let textWidth = label.intrinsicContentSize.width
        let height = min(bounds.height - 4, (label.font?.boundingRectForFont.height ?? 15) + 3)
        let rect = NSRect(x: 2, y: (bounds.height - height) / 2, width: min(textWidth + 10, bounds.width - 4), height: height)
        pillColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }
}

/// Plain text cell for size, kind, extension and tags.
final class FileTextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, alignment: NSTextAlignment = .left) {
        label.stringValue = text
        label.alignment = alignment
    }
}

/// Group header row ("Today", "Folders", a kind…) with the item count.
/// Group title: small grey bold text at the bottom of a taller row, no count, like the original's list groups.
final class FileGroupHeaderView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 11, weight: .bold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, count value: Int) {
        title.stringValue = text
        setAccessibilityLabel(text)
    }
}

/// Repository detection for the Git badge: a folder that contains `.git`.
@MainActor
enum GitRepositoryProbe {
    private static var cache: [String: (Bool, Date)] = [:]
    private static var pending: [String: [(Bool) -> Void]] = [:]
    private static var revisions: [String: UInt64] = [:]

    static func invalidate(_ url: URL) {
        cache.removeValue(forKey: url.path)
        revisions[url.path, default: 0] &+= 1
    }

    static func isRepository(_ url: URL) async -> Bool {
        if let (value, time) = cache[url.path], Date().timeIntervalSince(time) < 30 { return value }
        return await withCheckedContinuation { continuation in
            _ = isRepository(url) { continuation.resume(returning: $0) }
        }
    }

    static func isRepository(_ url: URL, completion: @escaping (Bool) -> Void) -> Bool {
        if let (value, time) = cache[url.path], Date().timeIntervalSince(time) < 30 { return value }
        let path = url.path
        let revision = revisions[path, default: 0]
        let requestKey = "\(path)|\(revision)"
        if pending[requestKey] != nil {
            pending[requestKey]?.append(completion)
        } else {
            pending[requestKey] = [completion]
            Task.detached(priority: .utility) {
                let value = FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
                await MainActor.run {
                    if revisions[path, default: 0] == revision { cache[path] = (value, Date()) }
                    let callbacks = pending.removeValue(forKey: requestKey) ?? []
                    callbacks.forEach { $0(value) }
                }
            }
        }
        return cache[path]?.0 ?? false
    }
}

/// The inline rename field; a plain text field that keeps its own outline instead of the system focus ring.
final class InlineRenameField: NSTextField {
    override class var cellClass: AnyClass? {
        get { InlineRenameFieldCell.self }
        set {}
    }

    override var acceptsFirstResponder: Bool { true }

    // The field editor covers the cell's own background, so the fill lives on the layer.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayerBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground()
    }

    private func applyLayerBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (backgroundColor ?? .textBackgroundColor).cgColor
        }
    }
}

/// Text inset 8 pt from the rounded border and centered vertically, like the original's rename box.
final class InlineRenameFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        var inset = rect.insetBy(dx: 8, dy: 0)
        let height = min(cellSize(forBounds: inset).height, inset.height)
        inset.origin.y += (inset.height - height) / 2
        inset.size.height = height
        return inset
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centered(super.drawingRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        clearEditorBackground(textObj)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        clearEditorBackground(textObj)
    }

    /// The field draws the background; the editor's own fill (and its clip view's) would show as a darker block.
    private func clearEditorBackground(_ editor: NSText) {
        editor.drawsBackground = false
        (editor.superview as? NSClipView)?.drawsBackground = false
    }
}
