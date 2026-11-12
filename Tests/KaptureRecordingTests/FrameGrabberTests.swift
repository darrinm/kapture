import AVFoundation
import XCTest
@testable import KaptureRecording

/// A movie whose frames cycle red, green, blue, so the frame a grab returns can be identified
/// by its color. Needs no Screen Recording permission: the frames are synthesized.
final class FrameGrabberTests: XCTestCase {
    private static let width = 320, height = 240, fps: Int32 = 10, frameCount = 9
    var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kapture-framegrab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testAGrabReturnsTheFrameShownAtThatTimeAtNativeSize() async throws {
        let movie = AVURLAsset(url: try await writeMovie())
        let duration = try await movie.load(.duration)
        // the middle of each frame's interval, so the expected frame is unambiguous
        for index in [0, 1, 4, 5, Self.frameCount - 1] {
            let time = CMTime(value: CMTimeValue(index * 2 + 1), timescale: Self.fps * 2)
            let image = try await FrameGrabber.frame(of: movie, at: time, duration: duration)
            XCTAssertEqual(image.width, Self.width)
            XCTAssertEqual(image.height, Self.height)
            XCTAssertEqual(Self.dominantChannel(of: image), index % 3, "frame \(index)")
        }
    }

    func testAGrabAtTheEndOfTheMovieReturnsTheLastFrame() async throws {
        let movie = AVURLAsset(url: try await writeMovie())
        let duration = try await movie.load(.duration)
        let image = try await FrameGrabber.frame(of: movie, at: duration, duration: duration)
        XCTAssertEqual(Self.dominantChannel(of: image), (Self.frameCount - 1) % 3)
    }

    /// 0 red, 1 green, 2 blue. H.264 does not round-trip exact values, so compare channels.
    private static func dominantChannel(of image: CGImage) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0..<3].enumerated().max { $0.element < $1.element }!.offset
    }

    private func writeMovie() async throws -> URL {
        let url = directory.appendingPathComponent("frames.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width,
            AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalDurationKey: 1.5],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width,
            kCVPixelBufferHeightKey as String: Self.height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Self.frameCount {
            while !input.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(for: .milliseconds(2))
            }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try XCTUnwrap(created)
            Self.fill(buffer, channel: frame % 3)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(frame), timescale: Self.fps)))
        }
        input.markAsFinished()
        // without an end time the last frame has no duration and the movie ends at its start
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(Self.frameCount), timescale: Self.fps))
        await writer.finishWriting()
        try XCTSkipUnless(writer.status == .completed, "no working H.264 encoder here")
        return url
    }

    /// Solid red, green or blue. The buffer is BGRA, so channel 0 (red) is byte 2.
    private static func fill(_ buffer: CVPixelBuffer, channel: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                let p = base + y * rowBytes + x * 4
                p[0] = channel == 2 ? 255 : 0
                p[1] = channel == 1 ? 255 : 0
                p[2] = channel == 0 ? 255 : 0
                p[3] = 255
            }
        }
    }
}
