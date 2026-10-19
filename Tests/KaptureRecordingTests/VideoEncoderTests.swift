import AVFoundation
import XCTest
@testable import KaptureRecording

final class VideoEncoderTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-encoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testSoftwareCapsTheLongEdgeAndKeepsDimensionsEven() {
        XCTAssertEqual(VideoEncoder.software.size(width: 5120, height: 2880).width, 2560)
        XCTAssertEqual(VideoEncoder.software.size(width: 5120, height: 2880).height, 1440)
        let portrait = VideoEncoder.software.size(width: 2234, height: 3456)
        XCTAssertEqual(portrait.height, 2560)
        XCTAssertEqual(portrait.width % 2, 0)
        let odd = VideoEncoder.software.size(width: 6000, height: 3333)
        XCTAssertEqual(odd.width, 2560)
        XCTAssertEqual(odd.height % 2, 0)
    }

    func testSmallRecordingsAndHardwareKeepTheirSize() {
        XCTAssertEqual(VideoEncoder.software.size(width: 1200, height: 800).width, 1200)
        XCTAssertEqual(VideoEncoder.hardware.size(width: 5120, height: 2880).width, 5120)
    }

    func testTheSoftwareFallbackWritesAMovie() async throws {
        // The settings RecordingSession uses when the probe fails, at a 5K display's capped size.
        let size = VideoEncoder.software.size(width: 5120, height: 2880)
        let completed = try await write(encoder: .software, width: size.width, height: size.height)
        XCTAssertTrue(completed, "software H.264 writes a complete movie")
    }

    func testTheProbeAgreesWithTheWriter() async throws {
        // What the probe exists for: when it says hardware works, a hardware recording completes,
        // and when it says it does not, a hardware recording fails. Either can be true on a given
        // Mac on a given day.
        let probe = VideoEncoder.hardwareEncodes(width: 1920, height: 1080)
        let completed = try await write(encoder: .hardware, width: 1920, height: 1080)
        XCTAssertEqual(probe, completed)
    }

    /// Writes 30 frames through AVAssetWriter with RecordingSession's video settings for this
    /// encoder, and reports whether the movie completed.
    private func write(encoder: VideoEncoder, width: Int, height: Int) async throws -> Bool {
        let url = directory.appendingPathComponent("\(encoder)-\(width).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalDurationKey: 1.5],
            AVVideoEncoderSpecificationKey: encoder.specification,
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
