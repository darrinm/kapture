// Grab Frames: a player over a recording's library file. One key press stores the frame on
// screen as a screenshot. Each grab is an ordinary capture (annotatable, shareable, synced) and
// appears in the strip under the player. No corner card is shown, because a session of several
// grabs would add one card per frame.
import AppKit
import AVKit
import KaptureCore
import KaptureDesign
import KaptureEditor
import KaptureIntelligence
import KaptureRecording

@MainActor
final class FrameGrabController {
    static let shared = FrameGrabController()
    var library: Library?
    private var open: [String: FrameGrabSession] = [:]

    func open(recordID: String) {
        guard let library,
              let record = try? library.db.queue.read({ try CaptureRecord.fetchOne($0, key: recordID) }),
              record.canGrabFrames else { return }
        if let existing = open[recordID] { existing.window.makeKeyAndOrderFront(nil); return }
        let session = FrameGrabSession(record: record, library: library) { [weak self] in
            self?.open.removeValue(forKey: recordID)
            ActivationPolicy.release()
        }
        open[recordID] = session
        ActivationPolicy.acquire()
        session.window.makeKeyAndOrderFront(nil)
    }
}

/// One Grab Frames window and everything it owns.
@MainActor
private final class FrameGrabSession {
    let window: FrameGrabWindow
    private let record: CaptureRecord
    private let library: Library
    /// The recording's current path and an asset opened on it. A rename or a sync moves the
    /// file while the window is open; `moveObserver` updates both, and grabs read this asset.
    private var asset: AVURLAsset
    private let player: AVPlayer
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

        window = FrameGrabWindow(
            contentRect: NSRect(origin: .zero, size: playerWindowSize(for: record, barHeight: Self.barHeight)),
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
        moveObserver = FileMoveObserver { [weak self] move in
            guard let self, move.moved(self.asset.url) else { return }
            self.asset = AVURLAsset(url: move.to)
            self.updateTitle()
        }
        // A trim or an edit synced from another Mac replaces the movie; a discard moves it to
        // the trash. The player would keep showing the old movie while grabs read the new file,
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

    private func updateTitle() {
        window.title = "Grab Frames — " + asset.url.lastPathComponent
    }

    private func buildContent() {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        let grabButton = NSButton(title: "Grab Frame", target: self, action: #selector(grabTapped))
        grabButton.bezelStyle = .rounded
        // Drawn as the default button. Return itself is handled in `handleKey`, which filters
        // key repeat; the key equivalent never receives it.
        grabButton.keyEquivalent = "\r"
        // space must reach the player, not press the button
        grabButton.refusesFirstResponder = true
        grabButton.toolTip = "Save the frame on screen as a screenshot (Return or G)"

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
        for view in [playerView, timeLabel, grabButton, stripScroll] as [NSView] {
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

            stripScroll.leadingAnchor.constraint(equalTo: grabButton.trailingAnchor, constant: 16),
            stripScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stripScroll.topAnchor.constraint(equalTo: playerView.bottomAnchor),
            stripScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            strip.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            strip.topAnchor.constraint(equalTo: clip.topAnchor),
            strip.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
        ])
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        grabButton.setContentHuggingPriority(.required, for: .horizontal)
        window.contentView = content
    }

    // MARK: keys

    /// Virtual key codes. G is matched by key code so Caps Lock, which makes the character "G",
    /// does not stop it.
    private enum Key {
        static let g: UInt16 = 5, space: UInt16 = 49, left: UInt16 = 123, right: UInt16 = 124
        static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76
    }

    /// Space plays and pauses, ←/→ step one frame, ⇧←/⇧→ jump one second, Return or G grabs.
    /// A held grab key stores one frame, not one per key repeat. Anything with ⌘, ⌃ or ⌥ is left
    /// for the menus.
    private func handleKey(_ event: NSEvent) -> Bool {
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
        default: return false
        }
        return true
    }

    /// Play from the start when the player is at the end, as AVPlayerView's own space key does.
    /// `play()` at the end time plays nothing.
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

    // MARK: grab

    @objc private func grabTapped() { grab() }

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
final class FrameGrabWindow: NSWindow {
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
