// Movie → optimized GIF. Kapture owns quantization (spec §4): one global median-cut palette
// built from sampled frames, Floyd–Steinberg dithering, indexed frames handed to ImageIO —
// avoiding its per-frame palettes (which shimmer between frames).
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import KaptureCore

public enum GIFExporter {
    public struct Result: Sendable {
        public let url: URL
        public let width: Int
        public let height: Int
        public let duration: Double
    }

    public static func export(movie url: URL, maxWidth: CGFloat = 960, fps: Int = 12) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.05 else { throw CocoaError(.fileReadCorruptFile) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)   // aspect preserved

        let frameCount = max(2, Int(duration * Double(fps)))
        let times = (0..<frameCount).map {
            CMTime(seconds: Double($0) / Double(fps), preferredTimescale: 600)
        }
        // Pass 1 — palette. Every frame is decoded on demand and released again: holding all
        // of them (as CGImages *and* RGBA buffers) costs ~1.4 GB for a 30s 960x540 clip and
        // will jetsam on anything longer. A couple of dozen evenly spaced frames cover the
        // clip's colors as well as sampling all of them did.
        var w = 0, h = 0
        var samples: [(UInt8, UInt8, UInt8)] = []
        samples.reserveCapacity(220_000)
        let paletteFrames = min(times.count, 24)
        let frameStride = max(1, times.count / paletteFrames)
        let perFrameBudget = max(1, 200_000 / paletteFrames)
        for (i, t) in times.enumerated() where i % frameStride == 0 {
            guard let img = try? generator.copyCGImage(at: t, actualTime: nil) else { continue }
            if w == 0 { w = img.width; h = img.height }
            guard let buf = rgba(img, width: w, height: h) else { continue }
            let step = max(1, (w * h) / perFrameBudget)
            var p = 0
            while p < w * h {
                samples.append((buf[p * 4], buf[p * 4 + 1], buf[p * 4 + 2]))
                p += step
            }
        }
        guard w > 0, h > 0, !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let palette = medianCut(samples, count: 256)
        samples = []

        // encode: indexed frames with FS dithering, single shared color table
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kapture-gif-\(ULID.generate()).gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                                         times.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let gifProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(dest, gifProps)
        let delay = 1.0 / Double(fps)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay,
            kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary

        var table: [UInt8] = []
        table.reserveCapacity(palette.count * 3)
        for c in palette { table.append(c.0); table.append(c.1); table.append(c.2) }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let indexedSpace = CGColorSpace(indexedBaseSpace: base,
                                              last: palette.count - 1, colorTable: table) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Pass 2 — encode, one frame resident at a time.
        var written = 0
        for t in times {
            guard let frame = try? generator.copyCGImage(at: t, actualTime: nil),
                  let buf = rgba(frame, width: w, height: h) else { continue }
            let indexed = ditherToPalette(buf, width: w, height: h, palette: palette)
            guard let provider = CGDataProvider(data: Data(indexed) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: w, space: indexedSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { continue }
            CGImageDestinationAddImage(dest, img, frameProps)
            written += 1
        }
        guard written > 0, CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return Result(url: out, width: w, height: h, duration: Double(written) * delay)
    }

    // MARK: internals

    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    private struct ColorBox {
        var pixels: [(UInt8, UInt8, UInt8)]
        var channel: Int    // widest channel
        var range: Int      // its spread; <= 0 means nothing left to separate
    }

    private static func medianCut(_ pixels: [(UInt8, UInt8, UInt8)], count: Int) -> [(UInt8, UInt8, UInt8)] {
        guard !pixels.isEmpty else { return [(0, 0, 0)] }
        // each box carries its own widest-channel spread, measured once when it is created —
        // rescanning every box on all 255 splits is ~255x the pixel reads for the same answer
        func makeBox(_ p: [(UInt8, UInt8, UInt8)]) -> ColorBox {
            guard p.count > 1 else { return ColorBox(pixels: p, channel: 0, range: 0) }
            let ranges = channelRanges(p)
            let widest = ranges.firstIndex(of: ranges.max()!)!
            return ColorBox(pixels: p, channel: widest, range: ranges[widest])
        }
        var boxes = [makeBox(pixels)]
        while boxes.count < count {
            // split the box with the widest channel range
            guard let index = boxes.indices.max(by: { boxes[$0].range < boxes[$1].range }),
                  boxes[index].range > 0 else { break }
            let box = boxes.remove(at: index)
            var sorted = box.pixels
            sorted.sort { component($0, box.channel) < component($1, box.channel) }
            let mid = sorted.count / 2
            boxes.append(makeBox(Array(sorted[..<mid])))
            boxes.append(makeBox(Array(sorted[mid...])))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for p in box.pixels { r += Int(p.0); g += Int(p.1); b += Int(p.2) }
            let n = max(1, box.pixels.count)
            return (UInt8(r / n), UInt8(g / n), UInt8(b / n))
        }
    }

    private static func channelRanges(_ box: [(UInt8, UInt8, UInt8)]) -> [Int] {
        var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
        for p in box {
            minR = min(minR, Int(p.0)); maxR = max(maxR, Int(p.0))
            minG = min(minG, Int(p.1)); maxG = max(maxG, Int(p.1))
            minB = min(minB, Int(p.2)); maxB = max(maxB, Int(p.2))
        }
        return [maxR - minR, maxG - minG, maxB - minB]
    }

    private static func component(_ p: (UInt8, UInt8, UInt8), _ c: Int) -> UInt8 {
        c == 0 ? p.0 : c == 1 ? p.1 : p.2
    }

    /// Floyd–Steinberg dither to the palette; nearest lookup accelerated by a 5-bit RGB cache.
    private static func ditherToPalette(_ rgba: [UInt8], width: Int, height: Int,
                                        palette: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        var cache = [Int16](repeating: -1, count: 32 * 32 * 32)
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            let cached = cache[key]
            if cached >= 0 { return Int(cached) }
            var best = 0, bestDist = Int.max
            for (i, c) in palette.enumerated() {
                let dr = r - Int(c.0), dg = g - Int(c.1), db = b - Int(c.2)
                let d = dr * dr + dg * dg + db * db
                if d < bestDist { bestDist = d; best = i }
            }
            cache[key] = Int16(best)
            return best
        }

        var out = [UInt8](repeating: 0, count: width * height)
        // error rows in 1/16ths
        var errR = [Int](repeating: 0, count: width + 2)
        var errG = [Int](repeating: 0, count: width + 2)
        var errB = [Int](repeating: 0, count: width + 2)
        for y in 0..<height {
            var nextR = [Int](repeating: 0, count: width + 2)
            var nextG = [Int](repeating: 0, count: width + 2)
            var nextB = [Int](repeating: 0, count: width + 2)
            for x in 0..<width {
                let o = (y * width + x) * 4
                let r = min(255, max(0, Int(rgba[o]) + errR[x + 1] / 16))
                let g = min(255, max(0, Int(rgba[o + 1]) + errG[x + 1] / 16))
                let b = min(255, max(0, Int(rgba[o + 2]) + errB[x + 1] / 16))
                let idx = nearest(r, g, b)
                out[y * width + x] = UInt8(idx)
                let c = palette[idx]
                let er = r - Int(c.0), eg = g - Int(c.1), eb = b - Int(c.2)
                errR[x + 2] += er * 7; errG[x + 2] += eg * 7; errB[x + 2] += eb * 7
                nextR[x] += er * 3; nextG[x] += eg * 3; nextB[x] += eb * 3
                nextR[x + 1] += er * 5; nextG[x + 1] += eg * 5; nextB[x + 1] += eb * 5
                nextR[x + 2] += er * 1; nextG[x + 2] += eg * 1; nextB[x + 2] += eb * 1
            }
            errR = nextR; errG = nextG; errB = nextB
        }
        return out
    }
}
