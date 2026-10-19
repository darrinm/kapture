import AVFoundation
import XCTest
@testable import KaptureRecording

final class EncoderProbeTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-encoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testTheProbeAgreesWithTheWriter() async throws {
        // What the probe exists for: when it says the encoder works, a recording's writer
        // completes, and when it says it does not, that writer fails. Either can be true on a
        // given Mac on a given day.
        let probe = EncoderProbe.hardwareEncodes(width: 1920, height: 1080)
        let completed = try await write(width: 1920, height: 1080)
        XCTAssertEqual(probe, completed)
    }

    /// Writes 30 frames through AVAssetWriter with RecordingSession's video settings and reports
    /// whether the movie completed.
    private func write(width: Int, height: Int) async throws -> Bool {
        let url = directory.appendingPathComponent("probe-\(width).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalDurationKey: 1.5],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer, adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(frame), timescale: 30)) else { break }
        }
        if writer.status == .writing {
            input.markAsFinished()
            await writer.finishWriting()
        }
        return writer.status == .completed
    }
}
