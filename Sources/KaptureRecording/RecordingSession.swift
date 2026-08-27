// Screen recording via ScreenCaptureKit (spike B-validated): SCStream delivers video, system
// audio (driverless capturesAudio), and mic (captureMicrophone) into an AVAssetWriter MP4.
// Audio timestamped before the session start is dropped — appending it corrupts the file.
import ScreenCaptureKit
import AVFoundation
import KaptureCore

public enum RecordingScope {
    case display(SCDisplay, scale: CGFloat)
    case area(SCDisplay, rectInPoints: CGRect, scale: CGFloat)
    case window(SCWindow, scale: CGFloat)
}

public final class RecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    // nil when that source is off — an input added to the writer but never fed leaves an
    // empty audio track in every movie
    private let sysAudio: AVAssetWriterInput?
    private let micAudio: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "sh.kapture.recording")
    private var started = false
    private var sessionStart = CMTime.invalid
    // pause/resume: samples are dropped while paused and every later sample is retimed by the
    // accumulated pause span, so the movie has no hole (spike C math).
    private let lock = NSLock()
    private var paused = false
    private var resuming = false
    private var pausedOffset = CMTime.zero
    private var lastAppendedEnd = CMTime.zero
    public var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    /// End of the last appended video frame, relative to the session start (pause spans excluded).
    private func recordedEnd() -> CMTime { lock.lock(); defer { lock.unlock() }; return lastAppendedEnd }

    public func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard value != paused else { return }
        paused = value
        // resuming is what makes the next video frame recompute the offset. Pausing before the
        // session even started has no span to fold in, so don't arm it.
        if !value, sessionStart.isValid { resuming = true }
    }
    public let outputURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public private(set) var startedAt: Date?

    public init(scope: RecordingScope, excludingWindows excluded: [SCWindow],
                captureMic: Bool, captureSystemAudio: Bool) throws {
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        switch scope {
        case .display(let display, let scale):
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            pixelWidth = Int(CGFloat(display.width) * scale)
            pixelHeight = Int(CGFloat(display.height) * scale)
        case .area(let display, let rect, let scale):
            filter = SCContentFilter(display: display, excludingWindows: excluded)
            config.sourceRect = rect
            pixelWidth = Int(rect.width * scale) / 2 * 2   // encoder wants even dimensions
            pixelHeight = Int(rect.height * scale) / 2 * 2
        case .window(let window, let scale):
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixelWidth = Int(window.frame.width * scale) / 2 * 2
            pixelHeight = Int(window.frame.height * scale) / 2 * 2
        }
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = captureSystemAudio
        config.excludesCurrentProcessAudio = true
        // SCK mic capture is 15+; the deployment floor is 14, where mic is simply unavailable
        // (AVCaptureSession fallback is spec'd for 14.x but deferred — Darrin's Macs run 15+).
        let micEnabled: Bool
        if #available(macOS 15.0, *), captureMic {
            config.captureMicrophone = true
            micEnabled = true
        } else {
            micEnabled = false
        }

        outputURL = Library.tempURL(prefix: "kapture-recording", ext: "mp4")
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalDurationKey: 1.5,   // bounds trim snap error (spec §4)
            ],
        ])
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ]
        sysAudio = captureSystemAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil
        micAudio = micEnabled ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil
        for input in [video, sysAudio, micAudio].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *), micEnabled {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
    }

    public func start() async throws {
        try await stream.startCapture()
        startedAt = Date()
    }

    public func stop() async throws -> MediaResult {
        try? await stream.stopCapture()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                // markAsFinished before startWriting raises NSInternalInconsistencyException —
                // reachable when the stop lands before the first in-size frame
                guard self.writer.status == .writing else { cont.resume(); return }
                for input in [self.video, self.sysAudio, self.micAudio].compactMap({ $0 }) {
                    input.markAsFinished()
                }
                self.writer.finishWriting { cont.resume() }
            }
        }
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        // recorded (not wall-clock) length: lastAppendedEnd is already pause-compensated,
        // so a paused recording doesn't report the pause span as movie duration
        let recorded = recordedEnd()
        let duration = started && recorded.isValid ? max(0, recorded.seconds) : 0
        return MediaResult(url: outputURL, width: pixelWidth, height: pixelHeight, duration: duration)
    }

    // Only the opening samples are interesting in the log, and this runs per delivered sample on
    // every stream — plain counters that stop climbing at 3 keep the hot path allocation-free.
    private var screenSamples = 0
    private var otherSamples = 0

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let n: Int
        if type == .screen {
            if screenSamples < 3 { screenSamples += 1 }
            n = screenSamples
        } else {
            if otherSamples < 3 { otherSamples += 1 }
            n = otherSamples
        }
        if n == 1 {
            Log.capture.info("record: first sample type=\(type.rawValue) valid=\(sb.isValid) ready=\(CMSampleBufferDataIsReady(sb))")
        }
        guard sb.isValid, CMSampleBufferDataIsReady(sb) else { return }
        // With sourceRect, SCK's first frames can arrive at full display size before the crop
        // applies; appending a mismatched frame into the sized encoder fails the writer (-16122).
        // Only frames at the configured dimensions start the session or get appended.
        if type == .screen {
            guard let pb = CMSampleBufferGetImageBuffer(sb),
                  CVPixelBufferGetWidth(pb) == pixelWidth,
                  CVPixelBufferGetHeight(pb) == pixelHeight else {
                if n <= 3 { Log.capture.info("record: skipping off-size frame #\(n)") }
                return
            }
        }
        if !started {
            guard type == .screen else { return }
            let ok = writer.startWriting()
            // under the lock: setPaused reads sessionStart from whatever thread pauses
            lock.lock()
            sessionStart = sb.presentationTimeStamp
            lock.unlock()
            writer.startSession(atSourceTime: sessionStart)
            started = true
            Log.capture.info("record: writer started ok=\(ok) status=\(self.writer.status.rawValue)")
        }
        guard sb.presentationTimeStamp >= sessionStart else { return }   // pre-session audio corrupts

        lock.lock()
        if paused { lock.unlock(); return }
        if resuming {
            // the new offset can only be computed from a video frame; audio arriving before it
            // would be retimed with the stale offset and land ahead of everything that follows,
            // making the audio track's timestamps non-monotonic (append fails, writer dies)
            guard type == .screen else { lock.unlock(); return }
            // fold the pause span into the offset: resumed media continues where we left off
            let target = lastAppendedEnd + CMTime(value: 1, timescale: 60)
            pausedOffset = sb.presentationTimeStamp - sessionStart - target
            resuming = false
        }
        let offset = pausedOffset
        lock.unlock()

        let retimed = offset == .zero ? sb : Self.retime(sb, by: offset)
        guard let retimed else { return }
        let input: AVAssetWriterInput?
        switch type {
        case .screen:
            input = video
            lock.lock()
            lastAppendedEnd = retimed.presentationTimeStamp - sessionStart
            lock.unlock()
        case .audio: input = sysAudio
        case .microphone: input = micAudio
        @unknown default: input = nil
        }
        if let input, input.isReadyForMoreMediaData { input.append(retimed) }
        if writer.status == .failed { Log.capture.error("recording writer failed: \(self.writer.error)") }
    }

    /// Audio buffers can't be retimed in place — every buffer is copied with shifted timing.
    private static func retime(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        // Video frames — and most audio buffers — carry one timing entry for the whole buffer.
        // That case needs no heap array at all, which matters on a 60fps sample path.
        if CMSampleBufferGetNumSamples(sb) <= 1 {
            var info = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &info) == noErr else { return nil }
            info.presentationTimeStamp = info.presentationTimeStamp - offset
            if info.decodeTimeStamp.isValid { info.decodeTimeStamp = info.decodeTimeStamp - offset }
            var single: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb,
                                                  sampleTimingEntryCount: 1, sampleTimingArray: &info,
                                                  sampleBufferOut: &single)
            return single
        }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: nil)
        for i in 0..<count {
            infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - offset
            if infos[i].decodeTimeStamp.isValid { infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb,
                                              sampleTimingEntryCount: count, sampleTimingArray: &infos,
                                              sampleBufferOut: &out)
        return out
    }
}
