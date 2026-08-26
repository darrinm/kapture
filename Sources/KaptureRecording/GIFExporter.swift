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
        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for t in times {
            if let img = try? generator.copyCGImage(at: t, actualTime: nil) { frames.append(img) }
        }
        guard let first = frames.first else { throw CocoaError(.fileReadCorruptFile) }
        let w = first.width, h = first.height

        // frames → RGBA buffers
        let buffers = frames.compactMap { rgba($0, width: w, height: h) }
        guard !buffers.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        // one global palette from subsampled pixels across all frames
        var samples: [(UInt8, UInt8, UInt8)] = []
        samples.reserveCapacity(220_000)
        let strideStep = max(1, (buffers.count * w * h) / 200_000)
        var i = 0
        for buf in buffers {
            var p = 0
            while p < w * h {
                if i % strideStep == 0 {
                    samples.append((buf[p * 4], buf[p * 4 + 1], buf[p * 4 + 2]))
                }
                i += 1; p += 1
            }
        }
        let palette = medianCut(samples, count: 256)

        // encode: indexed frames with FS dithering, single shared color table
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kapture-gif-\(ULID.generate()).gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                                         buffers.count, nil) else {
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

        for buf in buffers {
            let indexed = ditherToPalette(buf, width: w, height: h, palette: palette)
            guard let provider = CGDataProvider(data: Data(indexed) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: w, space: indexedSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { continue }
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return Result(url: out, width: w, height: h, duration: Double(buffers.count) * delay)
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

    private static func medianCut(_ pixels: [(UInt8, UInt8, UInt8)], count: Int) -> [(UInt8, UInt8, UInt8)] {
        guard !pixels.isEmpty else { return [(0, 0, 0)] }
        var boxes: [[(UInt8, UInt8, UInt8)]] = [pixels]
        while boxes.count < count {
            // split the box with the widest channel range
            guard let (index, channel) = boxes.enumerated().compactMap({ (i, box) -> (Int, Int, Int)? in
                guard box.count > 1 else { return nil }
                let ranges = channelRanges(box)
                let widest = ranges.firstIndex(of: ranges.max()!)!
                return (i, widest, ranges[widest])
            }).max(by: { $0.2 < $1.2 }).map({ ($0.0, $0.1) }) else { break }
            var box = boxes.remove(at: index)
            box.sort { component($0, channel) < component($1, channel) }
            let mid = box.count / 2
            boxes.append(Array(box[..<mid]))
            boxes.append(Array(box[mid...]))
        }
        return boxes.map { box in
            var r = 0, g = 0, b = 0
            for p in box { r += Int(p.0); g += Int(p.1); b += Int(p.2) }
            let n = max(1, box.count)
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
