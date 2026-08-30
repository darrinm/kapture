// UI sounds are played from the middle of gestures and animations, so what matters about them is
// not that they are heard but that starting one costs the caller nothing.
import XCTest
@testable import KaptureCore

final class SoundsTests: XCTestCase {
    /// `NSSound.play()` does not return until CoreAudio has the output device running — measured
    /// at 137ms on the first play of a run, and 27-30ms again whenever the device has been quiet
    /// for a few seconds. Called from `commitDiscard`, that landed between a swipe's release and
    /// the card's exit animation and read as the card stopping dead halfway through the gesture.
    func testPlayingASoundDoesNotBlockTheCaller() {
        let wasEnabled = Settings.shared.soundsEnabled
        let realPlayer = Sounds.player
        defer { Sounds.player = realPlayer; Settings.shared.soundsEnabled = wasEnabled }
        Settings.shared.soundsEnabled = true

        let played = expectation(description: "the sound still gets played")
        Sounds.player = { _ in
            Thread.sleep(forTimeInterval: 0.2)   // stands in for CoreAudio waking the device
            played.fulfill()
        }

        let start = CFAbsoluteTimeGetCurrent()
        Sounds.play("Bottle")
        let blocked = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(blocked, 0.05, "the caller waited for the device to start")
        wait(for: [played], timeout: 2)
    }

    func testTheToggleIsStillHonored() {
        let wasEnabled = Settings.shared.soundsEnabled
        let realPlayer = Sounds.player
        defer { Sounds.player = realPlayer; Settings.shared.soundsEnabled = wasEnabled }
        Settings.shared.soundsEnabled = false

        let silent = expectation(description: "nothing is played")
        silent.isInverted = true
        Sounds.player = { _ in silent.fulfill() }

        Sounds.play("Bottle")
        wait(for: [silent], timeout: 0.3)
    }
}
