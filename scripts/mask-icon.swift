// Masks Resources/icon-1024.png to a transparent-cornered macOS squircle → icon-masked.png
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = root.appendingPathComponent("Resources/icon-1024.png")
guard let img = NSImage(contentsOf: src),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("load") }

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// the generated squircle sits inset ~72px; clip to a matching continuous-corner path
let inset: CGFloat = 88
let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
let radius: CGFloat = rect.width * 0.235
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Resources/icon-masked.png"))
print("masked")
