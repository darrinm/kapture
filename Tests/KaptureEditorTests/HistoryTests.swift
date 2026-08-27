// Undo/redo now has buttons, and a button that lies about what it will do is worse than no
// button. These pin the history semantics the buttons report.
import XCTest
import AppKit
@testable import KaptureEditor

@MainActor
final class HistoryTests: XCTestCase {
    private func makeCanvas() -> CanvasView {
        let layer = Annotation(tool: .rect, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)],
                               colorHex: "#FF0000", strokeWidth: 6)
        return TestCanvas.make(layers: [layer], selectingMostRecent: true)
    }

    func testNothingToUndoOnAFreshCanvas() {
        let canvas = makeCanvas()
        XCTAssertFalse(canvas.canUndo)
        XCTAssertFalse(canvas.canRedo)
    }

    func testAnEditCanBeUndoneAndRedone() {
        let canvas = makeCanvas()
        canvas.rewidthSelected(20, recordUndo: true)
        XCTAssertEqual(canvas.layers.first?.strokeWidth, 20)
        XCTAssertTrue(canvas.canUndo)
        XCTAssertFalse(canvas.canRedo, "nothing has been undone yet")

        canvas.undo()
        XCTAssertEqual(canvas.layers.first?.strokeWidth, 6, "undo did not restore the old width")
        XCTAssertTrue(canvas.canRedo)

        canvas.redo()
        XCTAssertEqual(canvas.layers.first?.strokeWidth, 20, "redo did not reapply the edit")
        XCTAssertFalse(canvas.canRedo)
        XCTAssertTrue(canvas.canUndo)
    }

    /// The rule that makes redo trustworthy: editing after an undo abandons the branch you
    /// undid, so redo can never resurrect work that no longer follows from what is on screen.
    func testEditingAfterUndoDiscardsTheRedoBranch() {
        let canvas = makeCanvas()
        canvas.rewidthSelected(20, recordUndo: true)
        canvas.undo()
        XCTAssertTrue(canvas.canRedo)

        canvas.selectMostRecent()
        canvas.rewidthSelected(11, recordUndo: true)
        XCTAssertFalse(canvas.canRedo, "redo survived a new edit and now points at a dead branch")
        XCTAssertEqual(canvas.layers.first?.strokeWidth, 11)
    }

    func testHistoryChangesAreAnnounced() {
        let canvas = makeCanvas()
        var notifications = 0
        canvas.onHistoryChanged = { notifications += 1 }

        canvas.rewidthSelected(20, recordUndo: true)
        XCTAssertGreaterThan(notifications, 0, "the buttons would never learn an edit happened")
        let afterEdit = notifications
        canvas.undo()
        XCTAssertGreaterThan(notifications, afterEdit, "the buttons would not re-enable redo")
    }

    func testUndoingEverythingLeavesNothingToUndo() {
        let canvas = makeCanvas()
        canvas.rewidthSelected(20, recordUndo: true)
        canvas.undo()
        XCTAssertFalse(canvas.canUndo)
        canvas.undo()   // must be harmless
        XCTAssertFalse(canvas.canUndo)
        XCTAssertEqual(canvas.layers.first?.strokeWidth, 6)
    }
}
