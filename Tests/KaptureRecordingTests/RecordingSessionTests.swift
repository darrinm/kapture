import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import KaptureRecording

/// A real recording of the main display through ScreenCaptureKit and the writer. Skipped when
/// the process running the tests has no Screen Recording permission.
final class RecordingSessionTests: XCTestCase {
    func testRecordingTheDisplayProducesAMovieWithWhicheverEncoderWorks() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording permission")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let display = try XCTUnwrap(content.displays.first { $0.displayID == CGMainDisplayID() })
        let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / CGFloat(display.width)

        let session = try RecordingSession(scope: .display(display, scale: scale),
                                           excludingWindows: [], captureMic: false,
                                           captureSystemAudio: false)
        let failure = FailureBox()
        session.onFailure = { error in failure.error = error }
        try await session.start()
        try await Task.sleep(for: .seconds(2))
        let result = try await session.stop()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertNil(failure.error, "the writer did not fail")
        let native = Int(CGFloat(display.width) * scale)
        if session.encoder == .software {
            XCTAssertLessThanOrEqual(max(result.width, result.height), VideoEncoder.softwareMaxEdge)
        } else {
            XCTAssertEqual(result.width, native)
        }
        let tracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), result.width, "the movie is the size it reports")
        XCTAssertEqual(Int(size.height), result.height)
        print("recorded \(result.width)x\(result.height) with \(session.encoder)")
    }
}

private final class FailureBox: @unchecked Sendable {
    var error: Error?
}
