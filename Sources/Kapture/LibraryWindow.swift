// The library: a Photos-style borderless justified grid over the capture store (product spec
// §7.0). No per-item cards or labels — the name/tags appear on the hovered item only, selection
// is a thin accent outline. Search is FTS-backed and live; scopes double as the Trash view.
import AppKit
import QuickLookThumbnailing
import Quartz
import KaptureCore
import KaptureEditor
import KaptureDesign
import KaptureIntelligence

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
    private var searchDebounce: Task<Void, Never>?

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
        // the grid reports how many rows it drew; what that means is this view's business —
        // it owns the search field and both filter popups
        grid.onCountChanged = { [weak self] count in
            guard let self else { return }
            countLabel.stringValue = count == 1 ? "1 capture" : "\(count) captures"
            emptyLabel.isHidden = count > 0
            emptyLabel.stringValue = emptyMessage
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

    /// Why the grid is empty. "Nothing here yet" is only true with nothing narrowing the view —
    /// a full library hidden behind a search term or a filter needs a different answer.
    private var emptyMessage: String {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return "No captures match “\(query)”." }
        if appFilter.indexOfSelectedItem > 0 || dateFilter.indexOfSelectedItem > 0 {
            return "No captures match these filters."
        }
        return "Nothing here yet — press ⌘⇧4 to take a capture."
    }

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

    /// Typing is the one input that arrives faster than a query can answer it: without this,
    /// every keystroke ran a full FTS query and a thumbnail pass. Filter and scope changes are
    /// single deliberate clicks and stay immediate.
    func controlTextDidChange(_ obj: Notification) {
        let text = searchField.stringValue
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            grid.query = text
            grid.reload()
        }
    }
}

/// One thumbnail, off the main thread. Free-standing so the generating task never has to touch
/// the (main-actor) grid view.
private func generateThumbnail(_ url: URL, size: CGSize, scale: CGFloat) async -> CGImage? {
    let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                               representationTypes: .thumbnail)
    return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
}

/// Justified rows of thumbnails: no chrome per item, metadata on hover only.
final class LibraryGridView: NSView {
    private struct Item {
        let record: CaptureRecord
        var frame: CGRect = .zero
        var thumb: CGImage?
    }
    /// NSCache holds class instances only, so a generated thumbnail rides in a box.
    private final class ThumbBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    let library: Library
    var query = ""
    var scope: Library.SearchScope = .all
    var app: String?
    var range: Library.DateRange = .any
    var onCountChanged: ((Int) -> Void)?

    private var items: [Item] = []
    private var hovered: Int?
    private var selected: String?
    private let rowHeight: CGFloat = 168
    private let gutter: CGFloat = 4
    /// QuickLook is happy to work in parallel; four at a time fills a screen fast without
    /// starving the rest of the machine.
    private let thumbsInFlight = 4
    private var reloadTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var scrollSettle: Task<Void, Never>?

    /// Generated thumbnails, keyed so an entry self-invalidates: fastID changes on every edit
    /// and trim, so an edited capture can never redraw from stale pixels. Shared across reloads,
    /// which is the point — a keystroke, a filter change or a discard must not regenerate what
    /// is already in memory. Bounded, and NSCache drops entries under memory pressure too.
    private static let thumbCache: NSCache<NSString, ThumbBox> = {
        let cache = NSCache<NSString, ThumbBox>()
        cache.countLimit = 600
        return cache
    }()

    private static func thumbKey(_ record: CaptureRecord) -> String {
        "\(record.id):\(record.fastID)"
    }

    init(library: Library) {
        self.library = library
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                  object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// Scrolling brings new rows into view; generate those next. Coalesced so a flick doesn't
    /// restart the pass on every frame, and nearly free when the cache already has them.
    @objc private func visibleAreaChanged() {
        scrollSettle?.cancel()
        scrollSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.loadThumbnails()
        }
    }

    /// Re-run the query. The search itself goes off the main thread — the app has one
    /// serialized DB connection, so it can queue behind an ingest write — and a pass superseded
    /// by the next keystroke is cancelled before it can apply.
    func reload() {
        let (q, s, a, r) = (query, scope, app, range)
        reloadTask?.cancel()
        thumbTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let records = await library.searchAsync(q, scope: s, app: a, range: r)
            guard !Task.isCancelled else { return }
            apply(records)
        }
    }

    private func apply(_ records: [CaptureRecord]) {
        items = records.map { record in
            Item(record: record,
                 thumb: Self.thumbCache.object(forKey: Self.thumbKey(record) as NSString)?.image)
        }
        hovered = nil
        onCountChanged?(items.count)
        relayout()
        loadThumbnails()
    }

    // MARK: layout — justified rows, aspect preserved, tight uniform gutters

    /// Lay the rows out and return the height they need. It doesn't resize the view itself:
    /// setFrameSize calls back into layout, and the two used to bounce off each other until a
    /// half-point epsilon happened to stop them.
    private func layoutItems() -> CGFloat {
        let width = max(320, bounds.width)
        var y: CGFloat = gutter
        var row: [Int] = []
        var natural: CGFloat = 0   // the row's items at their unstretched widths

        func flush(scale: CGFloat) {
            guard !row.isEmpty else { return }
            var cursor = gutter
            for i in row {
                let w = items[i].frame.width * scale
                items[i].frame = CGRect(x: cursor, y: y, width: w, height: rowHeight * scale)
                cursor += w + gutter
            }
            y += rowHeight * scale + gutter
            row = []
            natural = 0
        }

        for i in items.indices {
            let r = items[i].record
            let aspect = r.height > 0 ? CGFloat(r.width) / CGFloat(r.height) : 1.6
            let w = min(max(rowHeight * aspect, 60), width - gutter * 2)
            // gutters for the row this item would join: one on each side plus one per item
            if natural + w + CGFloat(row.count + 2) * gutter > width, !row.isEmpty {
                flush(scale: (width - CGFloat(row.count + 1) * gutter) / natural)
            }
            items[i].frame = CGRect(x: 0, y: y, width: w, height: rowHeight)
            row.append(i)
            natural += w
        }
        flush(scale: 1)   // last row keeps natural size
        return max(y + gutter, 200)
    }

    private func relayout() {
        let height = layoutItems()
        let width = max(320, bounds.width)   // the width layoutItems just justified against
        if abs(height - frame.height) > 0.5 || abs(width - frame.width) > 0.5 {
            // super, not self: the override below would re-enter layout
            super.setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    // MARK: thumbnails — QuickLook handles stills, movies and GIFs alike
    private func loadThumbnails() {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let pending = items.indices.filter { items[$0].thumb == nil }
        // what the reader is looking at first, the rest trailing behind it
        let order = pending.filter { items[$0].frame.intersects(visible) }
            + pending.filter { !items[$0].frame.intersects(visible) }
        guard !order.isEmpty else { return }   // nothing missing: leave any running pass alone
        thumbTask?.cancel()

        let jobs = order.map { (index: $0, key: Self.thumbKey(items[$0].record),
                                url: library.url(for: items[$0].record)) }
        let size = CGSize(width: 480, height: 480)
        let scale = window?.backingScaleFactor ?? 2
        let limit = thumbsInFlight
        thumbTask = Task.detached(priority: .userInitiated) { [weak self] in
            let view = self   // immutable: the nested group closure can't capture the weak var
            await withTaskGroup(of: (index: Int, key: String, image: CGImage?).self) { group in
                var next = 0
                func start() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        (job.index, job.key, await generateThumbnail(job.url, size: size, scale: scale))
                    }
                }
                for _ in 0..<limit { start() }
                while let done = await group.next() {
                    // top of the iteration: a superseded pass stops here rather than running on
                    if Task.isCancelled { group.cancelAll(); break }
                    if let image = done.image {
                        await MainActor.run { view?.applyThumbnail(image, at: done.index, key: done.key) }
                    }
                    start()
                }
            }
        }
    }

    private func applyThumbnail(_ image: CGImage, at index: Int, key: String) {
        Self.thumbCache.setObject(ThumbBox(image), forKey: key as NSString)
        // the row at that index may have been replaced between the generate and this hop
        guard index < items.count, Self.thumbKey(items[index].record) == key else { return }
        items[index].thumb = image
        setNeedsDisplay(items[index].frame)
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
        Clipboard.write(url: library.url(for: r))
    }
    @objc private func revealSelected() {
        guard let r = selectedRecord else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.url(for: r)])
    }
    @objc private func discardSelected() { if let r = selectedRecord { discard(r) } }
    /// Restore *this* capture. Restoring "the last discarded" from a right-click on a specific
    /// trashed item put a different file back.
    @objc private func restoreSelected() {
        guard let record = selectedRecord,
              let restored = try? library.restore(id: record.id) else { return }
        // discard cancelled its ingest job; an unnamed capture needs another pass
        if restored.aiState.acceptsName {
            Task { await IngestQueue.shared.enqueue(restored.id, after: 0) }
        }
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
