// Screen recording via ScreenCaptureKit (spike B-validated): SCStream delivers video, system
// audio (driverless capturesAudio), and mic (captureMicrophone) into an AVAssetWriter MP4.
// Audio timestamped before the session start is dropped — appending it corrupts the file.
import ScreenCaptureKit
import AVFoundation
import KaptureCore

public struct RecordingResult: Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let duration: Double
}

public enum RecordingScope {
    case display(SCDisplay, scale: CGFloat)
    case area(SCDisplay, rectInPoints: CGRect, scale: CGFloat)
    case window(SCWindow, scale: CGFloat)
}

public final class RecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let sysAudio: AVAssetWriterInput
    private let micAudio: AVAssetWriterInput
    private let queue = DispatchQueue(label: "sh.kapture.recording")
    private var started = false
    private var sessionStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
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

        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kapture-recording-\(ULID.generate()).mp4")
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
        sysAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        for input in [video, sysAudio, micAudio] {
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

    public func stop() async throws -> RecordingResult {
        try? await stream.stopCapture()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                for input in [self.video, self.sysAudio, self.micAudio] { input.markAsFinished() }
                if self.writer.status == .writing {
                    self.writer.finishWriting { cont.resume() }
                } else {
                    cont.resume()
                }
            }
        }
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        let duration = started && lastVideoPTS.isValid && sessionStart.isValid
            ? (lastVideoPTS - sessionStart).seconds : 0
        return RecordingResult(url: outputURL, width: pixelWidth, height: pixelHeight, duration: duration)
    }

    private var sampleCounts: [Int: Int] = [:]

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let n = (sampleCounts[Int(type.rawValue)] ?? 0) + 1
        sampleCounts[Int(type.rawValue)] = n
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
            sessionStart = sb.presentationTimeStamp
            writer.startSession(atSourceTime: sessionStart)
            started = true
            Log.capture.info("record: writer started ok=\(ok) status=\(self.writer.status.rawValue)")
        }
        guard sb.presentationTimeStamp >= sessionStart else { return }   // pre-session audio corrupts
        let input: AVAssetWriterInput?
        switch type {
        case .screen: input = video; lastVideoPTS = sb.presentationTimeStamp
        case .audio: input = sysAudio
        case .microphone: input = micAudio
        @unknown default: input = nil
        }
        if let input, input.isReadyForMoreMediaData { input.append(sb) }
        if writer.status == .failed { Log.capture.error("recording writer failed: \(self.writer.error)") }
    }
}
