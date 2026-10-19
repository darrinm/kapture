import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import KaptureRecording

/// A real recording of the main display through ScreenCaptureKit and the writer. Skipped when
/// the process running the tests has no Screen Recording permission.
final class RecordingSessionTests: XCTestCase {
    func testARecordingEitherProducesAMovieOrRefusesToStart() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording permission")
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let display = try XCTUnwrap(content.displays.first { $0.displayID == CGMainDisplayID() })
        let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / CGFloat(display.width)
        let width = Int(CGFloat(display.width) * scale)
        let height = Int(CGFloat(display.height) * scale)

        func makeSession() throws -> RecordingSession {
            try RecordingSession(scope: .display(display, scale: scale), excludingWindows: [],
                                 captureMic: false, captureSystemAudio: false)
        }

        guard EncoderProbe.hardwareEncodes(width: width, height: height) else {
            // The encoder is down: the session refuses before capturing anything.
            XCTAssertThrowsError(try makeSession()) { error in
                XCTAssertTrue(error is EncoderProbe.Unavailable)
            }
            print("encoder unavailable: recording refused to start")
            return
        }

        let session = try makeSession()
        let failure = FailureBox()
        session.onFailure = { error in failure.error = error }
        try await session.start()
        try await Task.sleep(for: .seconds(2))
        let result = try await session.stop()
        defer { try? FileManager.default.removeItem(at: result.url) }

        XCTAssertNil(failure.error, "the writer did not fail")
        let tracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), width, "full display resolution")
        XCTAssertEqual(Int(size.height), height)
        print("recorded \(result.width)x\(result.height)")
    }
}

private final class FailureBox: @unchecked Sendable {
    var error: Error?
}
