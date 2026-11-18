// The recording window: one player over a recording's library file, for both trimming and
// grabbing frames. Double-click, ⌘E and "Trim or Grab Frames…" open it.
//
// Grab Frame (Return or G) stores the frame on screen as a screenshot. Each grab is an ordinary
// capture (annotatable, shareable, synced) and appears in the strip under the player. No corner
// card is shown, because a session of several grabs would add one card per frame.
//
// Trim (T) starts AVPlayerView's QuickTime-style trim controls. A confirmed trim exports
// passthrough (no re-encode; the recorder's 1.5s maximum keyframe interval bounds the snap
// error) and lands through Library.applyTrim: the original is kept in .originals/, the trimmed
// movie replaces the file, the window closes and the capture returns as a corner card.
import AppKit
import AVKit
import KaptureCore
import KaptureDesign
import KaptureEditor
import KaptureIntelligence
import KaptureRecording

@MainActor
final class RecordingWindowController {
    static let shared = RecordingWindowController()
    var library: Library?
    private var open: [String: RecordingWindowSession] = [:]

    func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.opensRecordingWindow else { return }
        if let existing = open[recordID] {
            ActivationPolicy.acquire(for: existing.window)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let session = RecordingWindowSession(record: record, library: library) { [weak self] in
            if let window = self?.open.removeValue(forKey: recordID)?.window {
                ActivationPolicy.release(for: window)
            }
        }
        open[recordID] = session
        ActivationPolicy.acquire(for: session.window)
        session.window.makeKeyAndOrderFront(nil)
    }
}

/// One recording window and everything it owns.
@MainActor
private final class RecordingWindowSession {
    let window: RecordingWindow
    private let record: CaptureRecord
    private let library: Library
    /// The recording's current path and an asset opened on it. A rename or a sync moves the
    /// file while the window is open; `moveObserver` updates both, and grabs read this asset.
    private var asset: AVURLAsset
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let grabButton = NSButton()
    private let trimButton = NSButton()
    /// While AVKit's trim controls are up, Return and esc belong to them, and grabbing is off.
    private var isTrimming = false { didSet { updateButtons() } }
    /// AVPlayerView cannot begin trimming until the player item has loaded.
    private var isReady = false { didSet { updateButtons() } }
    private var statusObservation: NSKeyValueObservation?
    private let timeLabel = NSTextField(labelWithString: "0:00.00")
    private let strip = NSStackView()
    private let stripScroll = NSScrollView()
    private var timeObserver: Any?
    private var closeObserver: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?
    private var moveObserver: FileMoveObserver?

    private static let barHeight: CGFloat = 76
    private static let thumbHeight: CGFloat = 52

    init(record: CaptureRecord, library: Library, onClose: @escaping @MainActor () -> Void) {
        self.record = record
        self.library = library
        asset = AVURLAsset(url: library.url(for: record))
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))

        window = RecordingWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize(for: record)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        updateTitle()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 300)
        buildContent()
        window.center()
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeLabel.stringValue = Tokens.timecode(time.seconds) }
        }
        statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            Task { @MainActor in self?.isReady = ready }
        }
        moveObserver = FileMoveObserver { [weak self] move in
            guard let self, move.moved(self.asset.url) else { return }
            self.asset = AVURLAsset(url: move.to)
            self.updateTitle()
        }
        // An edit synced from another Mac replaces the movie; a discard moves it to the trash. The player would keep showing the old movie while grabs read the new file,
        // so the window closes.
        let id = record.id
        changeObserver = NotificationCenter.default.addObserver(
            forName: Library.captureDidChange, object: library, queue: .main) { [weak self] note in
            guard let change = note.userInfo?[Library.captureChangeKey] as? CaptureChange,
                  change.captureID == id,
                  change.kind == .contentReplaced || change.kind == .trashed else { return }
            MainActor.assumeIsolated { self?.window.close() }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tearDown()
                onClose()
            }
        }
    }

    /// The session is released right after this, which also releases `moveObserver`.
    private func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in [closeObserver, changeObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateButtons() {
        grabButton.isEnabled = !isTrimming
        trimButton.isEnabled = !isTrimming && isReady
    }

    private func updateTitle() {
        window.title = asset.url.lastPathComponent
    }

    /// Content size: the movie at half its pixel width, at most 70% of the screen's width, above
    /// the bar, with the whole window at most 85% of the screen's height so a portrait
    /// recording's bar stays on screen.
    private static func windowSize(for record: CaptureRecord) -> NSSize {
        let aspect = record.height > 0 ? CGFloat(record.width) / CGFloat(record.height) : 16.0 / 9
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        var w = min(CGFloat(record.width) / 2, visible.width * 0.7)
        var h = w / aspect
        let maxHeight = visible.height * 0.85 - barHeight
        if h > maxHeight { h = maxHeight; w = h * aspect }
        return NSSize(width: max(560, w), height: max(320, h) + barHeight)
    }

    private func buildContent() {
        playerView.player = player
        playerView.controlsStyle = .inline

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        grabButton.title = "Grab Frame"
        grabButton.target = self
        grabButton.action = #selector(grabTapped)
        grabButton.bezelStyle = .rounded
        // Drawn as the default button. Return itself is handled in `handleKey`, which filters
        // key repeat; the key equivalent never receives it.
        grabButton.keyEquivalent = "\r"
        grabButton.toolTip = "Save the frame on screen as a screenshot (Return or G)"

        trimButton.title = "Trim…"
        trimButton.target = self
        trimButton.action = #selector(trimTapped)
        trimButton.bezelStyle = .rounded
        trimButton.toolTip = "Trim the start and end of the recording (T)"

        for button in [grabButton, trimButton] {
            button.refusesFirstResponder = true   // space must reach the player, not press a button
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        updateButtons()

        strip.orientation = .horizontal
        strip.spacing = 6
        strip.alignment = .centerY
        stripScroll.documentView = strip
        stripScroll.drawsBackground = false
        stripScroll.hasHorizontalScroller = true
        stripScroll.autohidesScrollers = true
        stripScroll.horizontalScrollElasticity = .allowed
        stripScroll.verticalScrollElasticity = .none
        strip.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        for view in [playerView, timeLabel, grabButton, trimButton, stripScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let clip = stripScroll.contentView
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.barHeight),

            timeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            timeLabel.centerYAnchor.constraint(equalTo: grabButton.centerYAnchor),
            grabButton.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            grabButton.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.barHeight / 2),

            trimButton.leadingAnchor.constraint(equalTo: grabButton.trailingAnchor, constant: 8),
            trimButton.centerYAnchor.constraint(equalTo: grabButton.centerYAnchor),

            stripScroll.leadingAnchor.constraint(equalTo: trimButton.trailingAnchor, constant: 16),
            stripScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stripScroll.topAnchor.constraint(equalTo: playerView.bottomAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        window.contentView = content
    }

    // MARK: keys

    /// Virtual key codes. G is matched by key code so Caps Lock, which makes the character "G",
    /// does not stop it.
    private enum Key {
        static let g: UInt16 = 5, t: UInt16 = 17, space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124
        static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
    }

    /// Space plays and pauses, ←/→ step one frame, ⇧←/⇧→ jump one second, Return or G grabs,
    /// T trims. A held grab key stores one frame, not one per key repeat. Anything with ⌘, ⌃ or
    /// ⌥ is left for the menus. While trimming, every key goes to AVKit's trim controls, where
    /// Return confirms and esc cancels.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !isTrimming else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty || mods == .shift else { return false }
        switch event.keyCode {
        case Key.space where mods.isEmpty: togglePlayback()
        case Key.left: step(forward: false, bySecond: mods == .shift)
        case Key.right: step(forward: true, bySecond: mods == .shift)
        case Key.g, Key.returnKey, Key.keypadEnter:
            // a `where` here would apply to the last pattern only
            guard mods.isEmpty else { return false }
            if !event.isARepeat { grab() }
        case Key.t where mods.isEmpty:
            if !event.isARepeat, trimButton.isEnabled { trimTapped() }
        default: return false
        }
        return true
    }

    /// Play from the start when the player is at the end, as AVPlayerView's own space key does.
    /// `play()` at the end time plays nothing. A trim whose export failed leaves its range on the
    /// item, so the start and end are the item's playback end times when they are set.
    private func togglePlayback() {
        guard player.timeControlStatus == .paused else { player.pause(); return }
        if let item = player.currentItem, item.duration.isNumeric, item.currentTime() >= item.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    private func step(forward: Bool, bySecond: Bool) {
        player.pause()
        guard let item = player.currentItem else { return }
        if bySecond {
            let target = item.currentTime() + CMTime(value: forward ? 1 : -1, timescale: 1)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            item.step(byCount: forward ? 1 : -1)
        }
    }

    // MARK: trim

    /// Reached only while the Trim button is enabled: the item has loaded and no trim is up.
    @objc private func trimTapped() {
        isTrimming = true
        player.pause()
        Task {
            await trim()
            isTrimming = false
        }
    }

    private func trim() async {
        guard playerView.canBeginTrimming, let item = player.currentItem else {
            Log.capture.error("recording window: Trim pressed but the player cannot begin trimming")
            return
        }
        let result = await playerView.beginTrimming()
        // The range is read once, then cleared on every outcome. AVKit does not document that it
        // restores the playback end times on cancel, and a range left on the item after a failed
        // export would stop playback early with no trim controls showing.
        let start = item.reversePlaybackEndTime.isValid && item.reversePlaybackEndTime.seconds > 0
            ? item.reversePlaybackEndTime : .zero
        let duration = item.duration.isNumeric ? item.duration : ((try? await asset.load(.duration)) ?? .zero)
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        item.reversePlaybackEndTime = .invalid
        item.forwardPlaybackEndTime = .invalid
        // Cancel must not export, and confirming the full range trims nothing.
        guard result == .okButton, start != .zero || end != duration else { return }
        await exportTrim(CMTimeRange(start: start, end: end))
    }

    /// On success this window closes, and the trimmed capture comes back as a corner card. On
    /// failure the window stays open, and a toast says why.
    private func exportTrim(_ range: CMTimeRange) async {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            Log.capture.error("recording window: export session creation failed")
            Toast.show("Trim failed — the recording could not be exported")
            return
        }
        let out = Library.tempURL(prefix: "kapture-trim", ext: "mp4")
        let id = record.id, library = library
        do {
            export.timeRange = range
            try await export.export(to: out, as: .mp4)
            // applyTrim copies the movie and hashes the original and the copy. That takes seconds
            // for a long recording, so it does not run on the main actor.
            try await Task.detached(priority: .userInitiated) {
                try library.applyTrim(id, trimmedURL: out, duration: range.duration.seconds)
            }.value
            Sounds.play("Glass")
            window.close()
            OverlayController.shared.showCard(recordID: id)
        } catch {
            try? FileManager.default.removeItem(at: out)
            Log.capture.error("recording window: trim export failed: \(error)")
            Toast.show(error, while: "Trim")
        }
    }

    // MARK: grab

    @objc private func grabTapped() { grab() }

    /// Reached only while no trim is up: the key handler and the disabled button both stop it.
    private func grab() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let time = item.currentTime(), duration = item.duration
        let asset = asset, library = library, sourceApp = record.sourceApp
        let thumbSize = Self.thumbnailSize(width: record.width, height: record.height)
        let thumbMaxEdge = max(thumbSize.width, thumbSize.height) * window.backingScaleFactor
        Task {
            do {
                // Decode, PNG encode, the library write and the thumbnail downscale take
                // hundreds of ms for a 5K frame, so none of them runs on the main actor.
                let (stored, fileURL, image, thumb) = try await Task.detached(priority: .userInitiated) {
                    let image = try await FrameGrabber.frame(of: asset, at: time, duration: duration)
                    guard let data = ImageEncoding.pngData(image) else { throw GrabError.encoding }
                    // Kept from the start: there is no corner card to keep or discard it.
                    let (stored, fileURL) = try library.storePNG(
                        data, width: image.width, height: image.height,
                        sourceApp: sourceApp, windowTitle: nil, screenID: nil, status: .kept)
                    // The strip holds a small copy. Keeping every grabbed frame at full size would
                    // hold tens of megabytes per grab for as long as the window is open.
                    let thumb = ImageEncoding.downscaled(image, maxEdge: thumbMaxEdge)
                    return (stored, fileURL, image, thumb)
                }.value
                AfterCapture.copyAndSave(url: fileURL, image: image)
                Sounds.play("Tink")
                addThumbnail(thumb, size: thumbSize, recordID: stored.id, time: time)
                await IngestQueue.shared.enqueue(stored.id, after: 0)
            } catch {
                Log.capture.error("frame grab failed: \(error)")
                Toast.show(error, while: "Grab Frame")
            }
        }
    }

    private enum GrabError: LocalizedError {
        case encoding
        var errorDescription: String? { "the frame could not be encoded as PNG" }
    }

    /// Every grab of a recording has the recording's pixel size, so every thumbnail has this size.
    private static func thumbnailSize(width: Int, height: Int) -> NSSize {
        NSSize(width: (thumbHeight * CGFloat(width) / CGFloat(max(height, 1))).rounded(), height: thumbHeight)
    }

    private func addThumbnail(_ image: CGImage?, size: NSSize, recordID: String, time: CMTime) {
        let thumb = FrameThumbnail(recordID: recordID)
        thumb.image = image.map { NSImage(cgImage: $0, size: size) }
        thumb.toolTip = "\(Tokens.timecode(time.seconds)) — double-click to edit"
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        thumb.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        strip.addArrangedSubview(thumb)
        strip.layoutSubtreeIfNeeded()
        thumb.scrollToVisible(thumb.bounds)
    }
}

/// Keys go to the session before the responder chain and before key equivalents. AVPlayerView
/// is first responder, and its own space and arrow handling seeks by more than one frame.
final class RecordingWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

/// A grabbed frame in the strip. Double-click opens it in the annotation editor.
private final class FrameThumbnail: NSImageView {
    private let recordID: String

    init(recordID: String) {
        self.recordID = recordID
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = Tokens.radiusControl
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { EditorController.shared.open(recordID: recordID) }
    }
}
