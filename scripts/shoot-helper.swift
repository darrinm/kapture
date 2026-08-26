// Synthetic-event helper for the visual-review photo shoot (needs Accessibility; run from Terminal).
// Usage: shoot-helper key <keycode> <cmd|shift|opt...>  |  move x y  |  click x y  |
//        down x y  |  dragto x y  |  up x y   (coords: CG global points, top-left origin)
import CoreGraphics
import Foundation

let args = CommandLine.arguments
func flags(_ s: [String]) -> CGEventFlags {
    var f = CGEventFlags()
    if s.contains("cmd") { f.insert(.maskCommand) }
    if s.contains("shift") { f.insert(.maskShift) }
    if s.contains("opt") { f.insert(.maskAlternate) }
    return f
}
let src = CGEventSource(stateID: .hidSystemState)

switch args[1] {
case "key":
    let code = CGKeyCode(UInt16(args[2])!)
    let f = flags(Array(args.dropFirst(3)))
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = f
        e.post(tap: .cghidEventTap)
        usleep(30_000)
    }
case "move":
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
case "click":
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
case "down":
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
case "dragto":
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
case "up":
    let p = CGPoint(x: Double(args[2])!, y: Double(args[3])!)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)!
        .post(tap: .cghidEventTap)
default:
    fputs("unknown command\n", stderr)
    exit(1)
}
