// The library: a Photos-style borderless justified grid over the capture store (product spec
// §7.0). No per-item cards or labels — the name/tags appear on the hovered item only, selection
// is a thin accent outline. Search is FTS-backed and live; scopes double as the Trash view.
import AppKit
import QuickLookThumbnailing
import Quartz
import KaptureCore
import KaptureEditor
import KaptureDesign

@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = LibraryWindowController()
    var library: Library?
    private var window: NSWindow?
    private var grid: LibraryGridView?
    private var content: LibraryContentView?

    func show() {
        if let window {
            content?.refresh()
            window.makeKeyAndOrderFront(nil)
            ActivationPolicy.acquire()
            return
        }
        guard let library else { return }
        let content = LibraryContentView(library: library)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Kapture Library"
        w.titlebarAppearsTransparent = false
        w.contentView = content
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 620, height: 420)
        window = w
        grid = content.grid
        self.content = content
        ActivationPolicy.acquire()
        w.makeKeyAndOrderFront(nil)
        content.focusSearch()
    }

    func reload() { grid?.reload() }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicy.release()
    }
}

/// Toolbar (search + scopes) above the grid.
final class LibraryContentView: NSView, NSSearchFieldDelegate {
    let library: Library
    let grid: LibraryGridView
    private let searchField = NSSearchField()
    private let scopeControl: NSSegmentedControl
    private let appFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dateFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")

    init(library: Library) {
        self.library = library
        self.grid = LibraryGridView(library: library)
        let scopes = Library.SearchScope.allCases
        scopeControl = NSSegmentedControl(labels: scopes.map(\.title), trackingMode: .selectOne,
                                          target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        searchField.placeholderString = "Search captures"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false

        scopeControl.selectedSegment = 0
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.segmentStyle = .texturedRounded

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = grid
        grid.onCountChanged = { [weak self] count, query, filtered in
            self?.countLabel.stringValue = count == 1 ? "1 capture" : "\(count) captures"
            self?.emptyLabel.isHidden = count > 0
            // "nothing here yet" is only true with nothing narrowing the view — a full library
            // hidden behind an app or date filter needs a different answer
            self?.emptyLabel.stringValue = !query.isEmpty ? "No captures match “\(query)”."
                : filtered ? "No captures match these filters."
                : "Nothing here yet — press ⌘⇧4 to take a capture."
        }

        appFilter.target = self
        appFilter.action = #selector(appFilterChanged)
        reloadAppFilter()

        dateFilter.addItems(withTitles: Library.DateRange.allCases.map(\.title))
        dateFilter.target = self
        dateFilter.action = #selector(dateFilterChanged)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        for v in [searchField, scopeControl, appFilter, dateFilter, countLabel, scroll, emptyLabel] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            scopeControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            scopeControl.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 12),
            appFilter.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            appFilter.leadingAnchor.constraint(equalTo: scopeControl.trailingAnchor, constant: 12),
            appFilter.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            dateFilter.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            dateFilter.leadingAnchor.constraint(equalTo: appFilter.trailingAnchor, constant: 8),
            dateFilter.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            countLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        grid.reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    func focusSearch() { window?.makeFirstResponder(searchField) }

    /// Re-read the library: the grid's contents and the source-app menu, which otherwise keeps
    /// the app list from whenever the window was first opened.
    func refresh() {
        reloadAppFilter()
        grid.reload()
    }

    /// Source-app menu, built from what the library actually holds. The current selection is
    /// preserved across a rebuild so a refresh can't silently drop an active filter.
    private func reloadAppFilter() {
        let selected = appFilter.selectedItem?.representedObject as? String
        let apps = library.sourceApps()
        appFilter.removeAllItems()
        appFilter.addItem(withTitle: "Any app")
        for app in apps {
            let short = app.split(separator: ".").last.map(String.init) ?? app
            let item = NSMenuItem(title: short.capitalized, action: nil, keyEquivalent: "")
            item.representedObject = app
            appFilter.menu?.addItem(item)
        }
        if let selected, let item = appFilter.menu?.items.first(where: {
            $0.representedObject as? String == selected
        }) {
            appFilter.select(item)
        } else if selected != nil {
            grid.app = nil   // the filtered app is gone from the library; fall back to "Any app"
        }
    }

    @objc private func appFilterChanged() {
        grid.app = appFilter.selectedItem?.representedObject as? String
        grid.reload()
    }

    @objc private func dateFilterChanged() {
        grid.range = Library.DateRange.allCases[max(0, dateFilter.indexOfSelectedItem)]
        grid.reload()
    }

    @objc private func scopeChanged() {
        grid.scope = Library.SearchScope.allCases[max(0, scopeControl.selectedSegment)]
        grid.reload()
    }

    func controlTextDidChange(_ obj: Notification) {
        grid.query = searchField.stringValue
        grid.reload()
    }
}

/// Justified rows of thumbnails: no chrome per item, metadata on hover only.
final class LibraryGridView: NSView {
    private struct Item {
        let record: CaptureRecord
        var frame: CGRect = .zero
        var thumb: CGImage?
    }
    let library: Library
    var query = ""
    var scope: Library.SearchScope = .all
    var app: String?
    var range: Library.DateRange = .any
    var onCountChanged: ((Int, String, Bool) -> Void)?

    private var items: [Item] = []
    private var hovered: Int?
    private var selected: String?
    private let rowHeight: CGFloat = 168
    private let gutter: CGFloat = 4
    private var loadGeneration = 0

    init(library: Library) {
        self.library = library
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        let records = library.search(query, scope: scope, app: app, range: range)
        items = records.map { Item(record: $0) }
        hovered = nil
        onCountChanged?(items.count, query, app != nil || range != .any)
        layoutItems()
        loadThumbnails()
    }

    // MARK: layout — justified rows, aspect preserved, tight uniform gutters
    private func layoutItems() {
        let width = max(320, bounds.width)
        var x: CGFloat = gutter, y: CGFloat = gutter
        var row: [Int] = []

        func flush(_ stretch: Bool) {
            guard !row.isEmpty else { return }
            let totalGut = CGFloat(row.count + 1) * gutter
            let scale = stretch ? (width - totalGut) / (x - gutter * CGFloat(row.count + 1)) : 1
            var cursor = gutter
            for i in row {
                let w = items[i].frame.width * scale
                items[i].frame = CGRect(x: cursor, y: y, width: w, height: rowHeight * scale)
                cursor += w + gutter
            }
            y += rowHeight * scale + gutter
            row = []
            x = gutter
        }

        for i in items.indices {
            let r = items[i].record
            let aspect = r.height > 0 ? CGFloat(r.width) / CGFloat(r.height) : 1.6
            let w = min(max(rowHeight * aspect, 60), width - gutter * 2)
            if x + w + gutter > width, !row.isEmpty { flush(true) }
            items[i].frame = CGRect(x: x, y: y, width: w, height: rowHeight)
            row.append(i)
            x += w + gutter
        }
        flush(false)   // last row keeps natural size
        setFrameSize(NSSize(width: width, height: max(y + gutter, 200)))
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { layoutItems() }
    }

    // MARK: thumbnails — QuickLook handles stills, movies and GIFs alike
    private func loadThumbnails() {
        loadGeneration += 1
        let generation = loadGeneration
        let urls = items.map { library.url(for: $0.record) }
        let size = CGSize(width: 480, height: 480)
        let scale = window?.backingScaleFactor ?? 2
        Task.detached(priority: .userInitiated) {
            for (i, url) in urls.enumerated() {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                           representationTypes: .thumbnail)
                guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                else { continue }
                let cg = rep.cgImage
                await MainActor.run {
                    guard generation == self.loadGeneration, i < self.items.count else { return }
                    self.items[i].thumb = cg
                    self.setNeedsDisplay(self.items[i].frame)
                }
            }
        }
    }

    // MARK: hit testing + interaction
    private func index(at point: CGPoint) -> Int? {
        items.firstIndex { $0.frame.contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let next = index(at: p)
        if next != hovered {
            if let old = hovered, old < items.count { setNeedsDisplay(items[old].frame) }
            hovered = next
            if let next { setNeedsDisplay(items[next].frame) }
        }
    }
    override func mouseExited(with event: NSEvent) {
        if let old = hovered, old < items.count { setNeedsDisplay(items[old].frame) }
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { selected = nil; needsDisplay = true; return }
        selected = items[i].record.id
        needsDisplay = true
        if event.clickCount == 2 { open(items[i].record) }
    }

    override func keyDown(with event: NSEvent) {
        guard let id = selected, let item = items.first(where: { $0.record.id == id }) else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 49: quickLook(item.record)                  // space
        case 36: open(item.record)                       // return
        case 51: discard(item.record)                    // delete
        default: super.keyDown(with: event)
        }
    }

    // MARK: actions
    private func open(_ record: CaptureRecord) {
        if record.canTrim { TrimmerController.shared.open(recordID: record.id) }
        else if record.canAnnotate { EditorController.shared.open(recordID: record.id) }
        else { quickLook(record) }
    }

    private func quickLook(_ record: CaptureRecord) {
        NSWorkspace.shared.open(library.url(for: record))
    }

    private func discard(_ record: CaptureRecord) {
        guard record.status != .trashed else { return }
        try? library.discard(record)
        Sounds.play("Bottle")
        reload()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = index(at: p) else { return nil }
        selected = items[i].record.id
        needsDisplay = true
        let record = items[i].record
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if record.status == .trashed {
            add("Restore", #selector(restoreSelected))
        } else {
            if record.canTrim { add("Trim…", #selector(openSelected)) }
            else if record.canAnnotate { add("Edit…", #selector(openSelected)) }
            add("Copy", #selector(copySelected))
            add("Reveal in Finder", #selector(revealSelected))
            menu.addItem(.separator())
            add("Discard", #selector(discardSelected))
        }
        return menu
    }
    private var selectedRecord: CaptureRecord? {
        items.first(where: { $0.record.id == selected })?.record
    }
    @objc private func openSelected() { if let r = selectedRecord { open(r) } }
    @objc private func copySelected() {
        guard let r = selectedRecord else { return }
        let url = library.url(for: r)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        if let img = NSImage(contentsOf: url) { NSPasteboard.general.writeObjects([img]) }
    }
    @objc private func revealSelected() {
        guard let r = selectedRecord else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.url(for: r)])
    }
    @objc private func discardSelected() { if let r = selectedRecord { discard(r) } }
    @objc private func restoreSelected() {
        guard selectedRecord != nil else { return }
        _ = try? library.restoreLastDiscarded()
        reload()
    }

    // MARK: drawing
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (i, item) in items.enumerated() where item.frame.intersects(dirty) {
            let r = item.frame
            if let thumb = item.thumb {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.draw(thumb, in: Tokens.aspectFill(CGSize(width: thumb.width, height: thumb.height), in: r))
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
                ctx.fill(r)
            }
            if item.record.id == selected {
                ctx.setStrokeColor(Tokens.accent.cgColor)
                ctx.setLineWidth(3)
                ctx.stroke(r.insetBy(dx: 1.5, dy: 1.5))
            }
            if hovered == i { drawHoverMetadata(item, in: r, ctx: ctx) }
        }
    }

    /// Name + duration on a bottom gradient — the only per-item chrome, and only on hover.
    private func drawHoverMetadata(_ item: Item, in r: CGRect, ctx: CGContext) {
        let band = CGRect(x: r.minX, y: r.maxY - 34, width: r.width, height: 34)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(band)
        var name = (item.record.relPath as NSString).lastPathComponent
        if item.record.status == .staged { name += "  (on overlay)" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        (name as NSString).draw(at: CGPoint(x: band.minX + 8, y: band.minY + 9), withAttributes: attrs)
        if let seconds = item.record.durationS {
            let text = Tokens.duration(seconds) as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: band.maxX - size.width - 8, y: band.minY + 9), withAttributes: attrs)
        }
        ctx.restoreGState()
    }
}
