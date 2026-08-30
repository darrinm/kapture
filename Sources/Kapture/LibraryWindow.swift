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
        // The controls live in the toolbar, so the content view runs the full height of the window
        // and the grid scrolls under a translucent title bar — one band of chrome rather than a
        // title bar with a second row of widgets stacked beneath it.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Kapture Library"
        w.contentView = content
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 720, height: 420)

        // before the toolbar: setting it asks the delegate for every item straight away, and the
        // delegate builds them out of the content view's controls
        self.content = content

        let toolbar = NSToolbar(identifier: "library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        // the count reads as a subtitle under the title, where Photos puts its date range
        content.onCountChanged = { [weak w] count in
            w?.subtitle = count == 1 ? "1 capture" : "\(count) captures"
        }

        window = w
        grid = content.grid
        content.updateZoomAvailability()
        ActivationPolicy.acquire()
        w.makeKeyAndOrderFront(nil)
        content.focusSearch()
    }

    /// The window is kept alive after it closes (isReleasedWhenClosed = false), so without this
    /// every share and unshare re-ran a full FTS query and grid rebuild for nothing.
    func reload() {
        guard window?.isVisible == true else { return }
        grid?.reload()
    }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicy.release()
    }
}

// MARK: - Toolbar
//
// Zoom on the left, the scope in the middle, the narrowing controls and search on the right —
// the shape Photos uses, and the reason the window needs no second row of chrome.
private extension NSToolbarItem.Identifier {
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let scope = NSToolbarItem.Identifier("scope")
    static let appFilter = NSToolbarItem.Identifier("appFilter")
    static let dateFilter = NSToolbarItem.Identifier("dateFilter")
    static let search = NSToolbarItem.Identifier("search")
}

extension LibraryWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.zoom, .flexibleSpace, .scope, .flexibleSpace, .appFilter, .dateFilter, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let content else { return nil }
        // A search field gets the system item, which is what gives it the collapse-to-a-magnifier
        // behaviour in a narrow window; the rest are the controls the content view already wires.
        if id == .search {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = content.searchField
            return item
        }
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .zoom:       item.view = content.zoomControl;  item.label = "Size"
        case .scope:      item.view = content.scopeControl; item.label = "Show"
        case .appFilter:  item.view = content.appFilter;    item.label = "App"
        case .dateFilter: item.view = content.dateFilter;   item.label = "Date"
        default: return nil
        }
        item.toolTip = item.label
        return item
    }
}

/// The grid and its empty state. The controls that drive it live in the window's toolbar — this
/// view owns and wires them, and hands them over to be placed there.
final class LibraryContentView: NSView, NSSearchFieldDelegate {
    let library: Library
    let grid: LibraryGridView
    let searchField = NSSearchField()
    let scopeControl: NSSegmentedControl
    let appFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let dateFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let zoomControl: NSSegmentedControl
    /// How the window titles itself — the count belongs in the title bar, not in a band below it.
    var onCountChanged: ((Int) -> Void)?
    private let emptyLabel = NSTextField(labelWithString: "")
    private var searchDebounce: Task<Void, Never>?

    init(library: Library) {
        self.library = library
        self.grid = LibraryGridView(library: library)
        let scopes = Library.SearchScope.allCases
        scopeControl = NSSegmentedControl(labels: scopes.map(\.title), trackingMode: .selectOne,
                                          target: nil, action: nil)
        zoomControl = NSSegmentedControl(images: [
            NSImage(systemSymbolName: "minus", accessibilityDescription: "Smaller")!,
            NSImage(systemSymbolName: "plus", accessibilityDescription: "Larger")!,
        ], trackingMode: .momentary, target: nil, action: nil)
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
            onCountChanged?(count)
            emptyLabel.isHidden = count > 0
            emptyLabel.stringValue = emptyMessage
        }

        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged)

        appFilter.target = self
        appFilter.action = #selector(appFilterChanged)
        reloadAppFilter()

        dateFilter.addItems(withTitles: Library.DateRange.allCases.map(\.title))
        dateFilter.target = self
        dateFilter.action = #selector(dateFilterChanged)

        // The scroll view fills the window, title bar included: the toolbar is translucent and the
        // grid is meant to pass under it, which is what makes the chrome one band instead of two.
        scroll.automaticallyAdjustsContentInsets = true
        for v in [scroll, emptyLabel] {
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
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
        return "Nothing here yet — press \(HotkeyCenter.shared.binding(for: .area).display) to take a capture."
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
            let item = NSMenuItem(title: Self.displayName(forBundleID: app), action: nil, keyEquivalent: "")
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

    /// What to call an app in the filter. Ask the system, which knows it as "Ghostty" or "Safari";
    /// the last component of a bundle id is a guess that reads fine for `com.apple.Safari` and
    /// turns `sh.kapture.app` into "App". Cached — the menu is rebuilt on every refresh, and
    /// resolving a bundle id touches the launch services database.
    private static var appNames: [String: String] = [:]

    private static func displayName(forBundleID id: String) -> String {
        if let known = appNames[id] { return known }
        let resolved = resolveName(id)
        appNames[id] = resolved
        return resolved
    }

    /// The bundle's own name, localized where the app provides one. Not `FileManager`'s display
    /// name, which is the filename and carries the ".app" for anyone who has Finder set to show
    /// extensions; and not the last component of the id, which is only ever a guess.
    private static func resolveName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            // uninstalled since the capture was taken — the id is all there is to go on
            return id.split(separator: ".").last.map(String.init)?.capitalized ?? id
        }
        let bundle = Bundle(url: url)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = bundle?.localizedInfoDictionary?[key] as? String { return name }
            if let name = bundle?.object(forInfoDictionaryKey: key) as? String { return name }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    @objc private func appFilterChanged() {
        grid.app = appFilter.selectedItem?.representedObject as? String
        grid.reload()
    }

    @objc private func dateFilterChanged() {
        grid.range = Library.DateRange.allCases[max(0, dateFilter.indexOfSelectedItem)]
        grid.reload()
    }

    @objc private func zoomChanged() {
        grid.zoom(by: zoomControl.selectedSegment == 0 ? -1 : 1)
        updateZoomAvailability()
    }

    /// The ends of the range are dimmed rather than silently doing nothing.
    func updateZoomAvailability() {
        zoomControl.setEnabled(grid.canZoomOut, forSegment: 0)
        zoomControl.setEnabled(grid.canZoomIn, forSegment: 1)
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

    /// A day's worth of captures. The grid is a stream of moments before it is a grid of files, so
    /// the day is the unit the eye is given to navigate by — the same reason Photos groups.
    private struct Section {
        let title: String
        var headerY: CGFloat = 0
        var bottom: CGFloat = 0
    }

    private var items: [Item] = []
    private var sections: [Section] = []
    private var hovered: Int?
    private var selected: String?
    /// Driven by the zoom control and remembered between openings.
    private var rowHeight: CGFloat { Tokens.gridRowHeights[Settings.shared.librarySizeIndex] }
    private let gutter = Tokens.gridGutter
    private let headerHeight: CGFloat = 34
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
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                  object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        // bounds change is scrolling; frame change is the window being resized, which is the only
        // way the grid hears that it has more width to justify into
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func visibleAreaResized() {
        relayout()
    }

    /// Scrolling brings new rows into view; generate those next. Coalesced so a flick doesn't
    /// restart the pass on every frame, and nearly free when the cache already has them.
    @objc private func visibleAreaChanged() {
        // The pinned header is positioned from the visible rect, so it is the one thing on screen
        // that scrolling moves *relative to* the document and therefore does not repaint itself.
        // The band covers where it pins, and where the next day's header pushes it out of.
        setNeedsDisplay(paintedStickyHeader)   // where it is, so it gets cleared
        setNeedsDisplay(CGRect(x: 0, y: stickyTop - headerHeight,   // and where it is going
                               width: bounds.width, height: headerHeight * 2))
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
    /// The width to justify rows against: what the scroll view is showing, not this view's own
    /// width. Its own is circular — the grid sets its frame from the layout it just computed
    /// against that same number, so it could never find out the window had been made wider, and
    /// the grid stayed at whatever width it happened to start at with empty space beside it.
    private var layoutWidth: CGFloat {
        max(320, enclosingScrollView?.contentSize.width ?? bounds.width)
    }

    private func layoutItems() -> CGFloat {
        let width = layoutWidth
        let rowHeight = self.rowHeight
        var y: CGFloat = gutter
        var row: [Int] = []
        var natural: CGFloat = 0   // the row's items at their unstretched widths
        sections = []

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

        var day: Date?
        for i in items.indices {
            let r = items[i].record
            let itemDay = Calendar.current.startOfDay(for: r.createdAt)
            if itemDay != day {
                // a day never continues a row from the day before it
                flush(scale: 1)
                if !sections.isEmpty { sections[sections.count - 1].bottom = y }
                sections.append(Section(title: Self.sectionTitle(itemDay), headerY: y))
                y += headerHeight
                day = itemDay
            }
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
        flush(scale: 1)   // a day's last row keeps natural size rather than stretching to fill
        if !sections.isEmpty { sections[sections.count - 1].bottom = y }
        return max(y + gutter, 200)
    }

    /// "Today" and "Yesterday" where they apply, the date otherwise — the reading a person does
    /// of their own recent captures, which is most of what this window is for.
    private static let sectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    private static func sectionTitle(_ day: Date) -> String {
        sectionFormatter.string(from: day)
    }

    private func relayout() {
        let height = layoutItems()
        let width = layoutWidth   // the width layoutItems just justified against
        if abs(height - frame.height) > 0.5 || abs(width - frame.width) > 0.5 {
            // super, not self: the override below would re-enter layout
            super.setFrameSize(NSSize(width: width, height: height))
        }
        needsDisplay = true
    }

    /// Step the thumbnail size. Returns false at the ends so the caller can dim the control.
    @discardableResult
    func zoom(by step: Int) -> Bool {
        let next = Settings.shared.librarySizeIndex + step
        guard Tokens.gridRowHeights.indices.contains(next) else { return false }
        Settings.shared.librarySizeIndex = next
        // Anchor on what is in view: without this a zoom keeps the scroll *offset* and the grid
        // jumps to an unrelated day, since every row above has just changed height.
        let anchor = items.firstIndex { $0.frame.intersects(enclosingScrollView?.documentVisibleRect ?? bounds) }
        relayout()
        if let anchor, items.indices.contains(anchor) {
            // lifted by the inset as well, or the row it anchors on lands under the toolbar
            var target = items[anchor].frame
            let lift = (enclosingScrollView?.contentInsets.top ?? 0) + headerHeight
            target.origin.y -= lift
            target.size.height += lift
            scrollToVisible(target)
        }
        return true
    }

    var canZoomIn: Bool { Tokens.gridRowHeights.indices.contains(Settings.shared.librarySizeIndex + 1) }
    var canZoomOut: Bool { Tokens.gridRowHeights.indices.contains(Settings.shared.librarySizeIndex - 1) }

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
            // an edited capture's link points at the pixels as they were, so offer to refresh it
            if record.shareURL != nil {
                add(record.shareStale ? "Update Share Link" : "Copy Share Link", #selector(shareSelected))
                add("Delete Share Link", #selector(unshareSelected))
            } else {
                add("Share Link", #selector(shareSelected))
            }
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
    @objc private func shareSelected() {
        guard let r = selectedRecord else { return }
        ShareCoordinator.shared.share(r)
    }
    @objc private func unshareSelected() {
        guard let r = selectedRecord else { return }
        ShareCoordinator.shared.unshare(r)
    }
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
                ctx.addPath(Self.tile(r)); ctx.clip()   // before the flip: the view's own coordinates
                // This view is flipped and `CGContext.draw` is not, so drawn straight the whole
                // library came out upside down. Flipped about the destination box rather than
                // going through `NSImage.draw` as the share badge does: the grid repaints on
                // every scroll frame, and that path would allocate an image per thumbnail per
                // frame for something this does with two transforms.
                let box = Tokens.aspectFill(CGSize(width: thumb.width, height: thumb.height), in: r)
                ctx.translateBy(x: 0, y: box.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(thumb, in: CGRect(x: box.minX, y: 0, width: box.width, height: box.height))
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.quaternaryLabelColor.cgColor)
                ctx.addPath(Self.tile(r)); ctx.fillPath()
            }
            if item.record.id == selected {
                ctx.setStrokeColor(Tokens.accent.cgColor)
                ctx.setLineWidth(3)
                ctx.addPath(Self.tile(r.insetBy(dx: 1.5, dy: 1.5))); ctx.strokePath()
            }
            if item.record.shareURL != nil { drawShareBadge(item, in: r, ctx: ctx) }
            if hovered == i { drawHoverMetadata(item, in: r, ctx: ctx) }
        }

        // after the items: the header of the day you are inside stays with you, and it has to be
        // drawn over the thumbnails passing beneath it
        drawSectionHeaders(dirty, ctx: ctx)
    }

    /// A thumbnail's outline. Rounded, so the grid reads as a set of things rather than a sheet.
    private static func tile(_ r: CGRect) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: Tokens.radiusThumb, cornerHeight: Tokens.radiusThumb,
               transform: nil)
    }

    /// Where a section's header is drawn right now: at its own place in the document, or pinned to
    /// the top of the view while that day is the one on screen — and pushed back off the top by
    /// the next day's header as it arrives, so the two never overlap.
    private func headerFrame(_ index: Int, visibleTop: CGFloat) -> CGRect {
        let section = sections[index]
        var y = section.headerY
        if section.headerY < visibleTop, section.bottom > visibleTop {
            let next = index + 1 < sections.count ? sections[index + 1].headerY : .greatestFiniteMagnitude
            y = min(visibleTop, next - headerHeight)
        }
        return CGRect(x: 0, y: y, width: bounds.width, height: headerHeight)
    }

    /// Where a pinned header sits: below the toolbar, not under it. The grid runs the full height
    /// of the window so it can scroll beneath a translucent title bar, which means the top of
    /// `documentVisibleRect` is behind the toolbar — the content inset is the rest of the answer.
    private var stickyTop: CGFloat {
        guard let scroll = enclosingScrollView else { return 0 }
        return scroll.documentVisibleRect.minY + scroll.contentInsets.top
    }

    /// Where a held header was last painted. A header pinned to the top of the view is positioned
    /// from the visible rect, so scrolling does not move it the way it moves everything else, and
    /// nothing else will invalidate where it used to be — and it paints an opaque band, so a copy
    /// left behind simply stays on screen. A flick moves further in one event than the header is
    /// tall, so the old "invalidate a band around the top" left a trail of day headers down the
    /// grid. Recorded against the painting, like the selection view's chrome.
    private var paintedStickyHeader: CGRect = .zero

    private func drawSectionHeaders(_ dirty: NSRect, ctx: CGContext) {
        let visibleTop = stickyTop
        var held = CGRect.zero
        defer { paintedStickyHeader = held }
        for i in sections.indices {
            let frame = headerFrame(i, visibleTop: visibleTop)
            // recorded whatever the dirty rect lets us paint: it is where the header *is*
            if frame.minY != sections[i].headerY {
                held = held.isEmpty ? frame : held.union(frame)
            }
            guard frame.intersects(dirty) else { continue }
            // an opaque band, because thumbnails scroll underneath a pinned one
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(frame)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            (sections[i].title as NSString).draw(at: CGPoint(x: gutter, y: frame.minY + 9),
                                                 withAttributes: attrs)
        }
    }

    /// The one piece of always-on per-item chrome, because "is this one public?" is state the
    /// grid must answer without a hover: a small glyph in the top-right, amber when the link
    /// points at pixels the capture no longer has.
    private func drawShareBadge(_ item: Item, in r: CGRect, ctx: CGContext) {
        let box = CGRect(x: r.maxX - 24, y: r.minY + 6, width: 18, height: 18)
        ctx.setFillColor(Tokens.badgeScrim.cgColor)
        ctx.fillEllipse(in: box)
        // NSImage.draw, not CGContext.draw: this view is flipped, and only the AppKit path
        // orients the glyph for it
        let glyph = item.record.shareStale ? Self.staleGlyph : Self.sharedGlyph
        glyph?.draw(in: box.insetBy(dx: 4, dy: 4))
    }

    /// Tinted once each: building a symbol image costs a render, and the grid redraws on scroll.
    private static let sharedGlyph = shareGlyph(NSColor.white)
    private static let staleGlyph = shareGlyph(NSColor.systemOrange)

    private static func shareGlyph(_ tint: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return NSImage(systemSymbolName: "link", accessibilityDescription: "Shared")?
            .withSymbolConfiguration(config)
    }

    /// Name + duration on a bottom gradient — the only per-item chrome, and only on hover.
    private func drawHoverMetadata(_ item: Item, in r: CGRect, ctx: CGContext) {
        let band = CGRect(x: r.minX, y: r.maxY - 34, width: r.width, height: 34)
        ctx.saveGState()
        ctx.addPath(Self.tile(r)); ctx.clip()   // so the band takes the tile's bottom corners
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
