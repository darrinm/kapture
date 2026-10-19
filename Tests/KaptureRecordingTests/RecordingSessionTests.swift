import AVFoundation
import CoreGraphics
import KaptureCore
import ScreenCaptureKit
import XCTest
@testable import KaptureRecording

/// A real recording of the main display through ScreenCaptureKit and the writer. Skipped when
/// the process running the tests has no Screen Recording permission, and when the screen does
/// not change during the recording: SCK delivers a frame only when something on screen moves.
final class RecordingSessionTests: XCTestCase {
    func testARecordingProducesAMovieOrReportsTheEncoderFailure() async throws {
        try XCTSkipUnless(CGPreflightScreenCaptureAccess(), "needs Screen Recording permission")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            throw XCTSkip("cannot list displays: \(error)")
        }
        let display = try XCTUnwrap(content.displays.first { $0.displayID == CGMainDisplayID() })
        let scale = CGFloat(CGDisplayPixelsWide(display.displayID)) / CGFloat(display.width)
        let encoderWorks = EncoderProbe.probe() != .fails

        let session = try RecordingSession(scope: .display(display, scale: scale),
                                           excludingWindows: [], captureMic: false,
                                           captureSystemAudio: false)
        let failure = FailureBox()
        session.onFailure = { error in failure.error = error }
        try await session.start()
        try await Task.sleep(for: .seconds(2))
        let stopped: Result<MediaResult, Error>
        do { stopped = .success(try await session.stop()) } catch { stopped = .failure(error) }
        if case .success(let result) = stopped {
            // The writer starts on the first frame, so no file means no frame arrived.
            try XCTSkipIf(failure.error == nil
                          && !FileManager.default.fileExists(atPath: result.url.path),
                          "the screen did not change, so no frame was delivered")
        }

        guard encoderWorks else {
            // With the encoder down the writer fails on its first frame and says so.
            XCTAssertNotNil(failure.error, "the failure is reported while recording")
            if case .success(let result) = stopped { try? FileManager.default.removeItem(at: result.url) }
            return
        }
        XCTAssertNil(failure.error, "the writer did not fail")
        let result = try stopped.get()
        defer { try? FileManager.default.removeItem(at: result.url) }
        let tracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), Int(CGFloat(display.width) * scale), "full resolution")
        XCTAssertEqual(Int(size.height), Int(CGFloat(display.height) * scale))
    }
}

private final class FailureBox: @unchecked Sendable {
    var error: Error?
}
