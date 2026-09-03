import XCTest
import AppKit
@testable import KaptureDesign

/// The hover fill is the whole of a borderless glyph control's feedback, so the two things that
/// can silently take it away — a resting fill it has to composite over, and a state that never
/// clears — are what these cover.
final class HoverButtonTests: XCTestCase {

    private func alpha(_ c: NSColor) -> CGFloat {
        c.usingColorSpace(.sRGB)!.alphaComponent
    }
    private func brightness(_ c: NSColor) -> CGFloat {
        c.usingColorSpace(.sRGB)!.brightnessComponent
    }

    // MARK: fill derivation

    func testHoverFillOverNothingIsPlainWhite() {
        let fill = Tokens.controlFill(over: nil, brightenedBy: Tokens.controlHoverAlpha)
        XCTAssertEqual(alpha(fill), Tokens.controlHoverAlpha, accuracy: 0.001)
        XCTAssertEqual(brightness(fill), 1, accuracy: 0.001)
    }

    /// The pin's close button rests on a scrim that is the only reason its glyph reads over
    /// arbitrary pinned content. Hover must brighten it, not swap it for translucent white.
    func testHoverFillOverAScrimKeepsTheScrimAndBrightens() {
        let scrim = Tokens.badgeScrim
        let fill = Tokens.controlFill(over: scrim, brightenedBy: Tokens.controlHoverAlpha)
        XCTAssertGreaterThan(brightness(fill), brightness(scrim))
        XCTAssertEqual(alpha(fill), alpha(scrim), accuracy: 0.001,
                       "hover should lift the scrim's colour, not change how much it weighs")
    }

    func testPressReadsHeavierThanHover() {
        for resting: NSColor? in [nil, Tokens.badgeScrim] {
            let hover = Tokens.controlFill(over: resting, brightenedBy: Tokens.controlHoverAlpha)
            let press = Tokens.controlFill(over: resting, brightenedBy: Tokens.controlPressAlpha)
            XCTAssertNotEqual(hover, press)
            if resting == nil {
                XCTAssertGreaterThan(alpha(press), alpha(hover))
            } else {
                XCTAssertGreaterThan(brightness(press), brightness(hover))
            }
        }
    }

    // MARK: button state

    private func button(restingFill: NSColor? = nil) -> HoverButton {
        let b = HoverButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "t")!,
                            tip: "t")
        b.restingFill = restingFill
        b.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        return b
    }

    private func enterExit() -> NSEvent {
        NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                               timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    func testRestingButtonHasNoFillUntilHovered() {
        let b = button()
        XCTAssertNil(b.layer?.backgroundColor)
        b.mouseEntered(with: enterExit())
        XCTAssertNotNil(b.layer?.backgroundColor, "hovering a card control must show something")
        b.mouseExited(with: enterExit())
        XCTAssertNil(b.layer?.backgroundColor)
    }

    /// Card chrome is hidden the instant the pointer leaves the card, and a view hidden out from
    /// under the pointer never gets `mouseExited` — the button would come back still lit.
    ///
    /// Hiding the *stack view* rather than the button is how the overlay card does it, and it is
    /// the case that matters: this asserts AppKit really does propagate the hide down to the
    /// button, which is the whole mechanism the fix leans on.
    func testHidingTheChromeClearsTheHoverOnItsButtons() {
        let b = button()
        let chrome = NSStackView(views: [b])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(chrome)

        b.mouseEntered(with: enterExit())
        XCTAssertNotNil(b.layer?.backgroundColor)
        chrome.isHidden = true
        XCTAssertNil(b.layer?.backgroundColor,
                     "a control hidden out from under the pointer must not come back still lit")
    }

    func testHoverOverAScrimKeepsTheScrimWhenTheHoverEnds() {
        let b = button(restingFill: Tokens.badgeScrim)
        let resting = b.layer?.backgroundColor
        XCTAssertNotNil(resting)
        b.mouseEntered(with: enterExit())
        XCTAssertNotEqual(b.layer?.backgroundColor, resting)
        b.mouseExited(with: enterExit())
        XCTAssertEqual(b.layer?.backgroundColor, resting)
    }

    func testADisabledControlDoesNotPretendToBePressable() {
        let b = button(restingFill: Tokens.badgeScrim)
        b.isEnabled = false
        let resting = b.layer?.backgroundColor
        b.mouseEntered(with: enterExit())
        XCTAssertEqual(b.layer?.backgroundColor, resting)
    }
}
