// Movie → optimized GIF. Kapture owns quantization (spec §4): one global median-cut palette
// built from sampled frames, Floyd–Steinberg dithering, indexed frames handed to ImageIO —
// avoiding its per-frame palettes (which shimmer between frames).
import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import KaptureCore

public enum GIFExporter {
    public static func export(movie url: URL, maxWidth: CGFloat = 960, fps: Int = 12) async throws -> MediaResult {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.05 else { throw CocoaError(.fileReadCorruptFile) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Half a GIF frame interval. A seek landing anywhere inside the frame's own on-screen
        // window is invisible in the output, and the slack lets the generator answer from the
        // frames it has already decoded instead of seeking exactly (which forces a re-decode).
        let tolerance = CMTime(value: 1, timescale: Int32(fps * 2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)   // aspect preserved

        let frameCount = max(2, Int(duration * Double(fps)))
        let times = (0..<frameCount).map {
            CMTime(seconds: Double($0) / Double(fps), preferredTimescale: 600)
        }

        let (palette, w, h) = try await samplePalette(generator: generator, times: times)
        let space = try indexedSpace(for: palette)

        let out = Library.tempURL(prefix: "kapture-gif", ext: "gif")
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

        // The nearest-palette-entry answer for a 5-bit RGB cell is a property of the palette, not
        // of a frame, so the cache lives across the whole encode: the 256-way search runs a few
        // thousand times for the entire GIF instead of once per frame.
        var cache = [Int16](repeating: -1, count: 32 * 32 * 32)

        // Pass 2 — encode, one frame resident at a time.
        var written = 0
        for await result in generator.images(for: times) {
            guard case .success(_, let frame, _) = result,
                  let buf = rgba(frame, width: w, height: h) else { continue }
            let indexed = ditherToPalette(buf, width: w, height: h, palette: palette, cache: &cache)
            guard let provider = CGDataProvider(data: Data(indexed) as CFData),
                  let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: w, space: space,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { continue }
            CGImageDestinationAddImage(dest, img, frameProps)
            written += 1
        }
        guard written > 0, CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return MediaResult(url: out, width: w, height: h, duration: Double(written) * delay)
    }

    // MARK: internals

    /// Pass 1 — the global palette, plus the frame dimensions the whole export runs at.
    /// Every frame is decoded on demand and released again: holding all of them (as CGImages
    /// *and* RGBA buffers) costs ~1.4 GB for a 30s 960x540 clip and will jetsam on anything
    /// longer. A couple of dozen evenly spaced frames cover the clip's colors as well as
    /// sampling all of them did.
    private static func samplePalette(generator: AVAssetImageGenerator, times: [CMTime]) async throws
        -> (palette: [(UInt8, UInt8, UInt8)], width: Int, height: Int) {
        let paletteFrames = min(times.count, 24)
        let frameStride = max(1, times.count / paletteFrames)
        let perFrameBudget = max(1, 200_000 / paletteFrames)
        let sampled = times.enumerated().filter { $0.offset % frameStride == 0 }.map(\.element)

        var w = 0, h = 0
        var samples: [(UInt8, UInt8, UInt8)] = []
        samples.reserveCapacity(220_000)
        for await result in generator.images(for: sampled) {
            guard case .success(_, let img, _) = result else { continue }
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
        return (medianCut(samples, count: 256), w, h)
    }

    /// Indexed color space carrying the palette as the GIF's single shared color table.
    private static func indexedSpace(for palette: [(UInt8, UInt8, UInt8)]) throws -> CGColorSpace {
        var table: [UInt8] = []
        table.reserveCapacity(palette.count * 3)
        for c in palette { table.append(c.0); table.append(c.1); table.append(c.2) }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let space = CGColorSpace(indexedBaseSpace: base,
                                       last: palette.count - 1, colorTable: table) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return space
    }

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
            let widest = widestChannel(p)
            return ColorBox(pixels: p, channel: widest.channel, range: widest.range)
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

    /// The channel with the largest min→max spread across the box, and that spread.
    /// Ties go to the earlier channel (R before G before B).
    private static func widestChannel(_ box: [(UInt8, UInt8, UInt8)]) -> (channel: Int, range: Int) {
        var lo = SIMD3<Int>(repeating: 255), hi = SIMD3<Int>(repeating: 0)
        for p in box {
            let v = SIMD3<Int>(Int(p.0), Int(p.1), Int(p.2))
            lo = pointwiseMin(lo, v)
            hi = pointwiseMax(hi, v)
        }
        let spread = hi &- lo
        if spread.x >= spread.y && spread.x >= spread.z { return (0, spread.x) }
        return spread.y >= spread.z ? (1, spread.y) : (2, spread.z)
    }

    private static func component(_ p: (UInt8, UInt8, UInt8), _ c: Int) -> UInt8 {
        c == 0 ? p.0 : c == 1 ? p.1 : p.2
    }

    /// Nearest palette entry to `v`, memoized per 5-bit RGB cell in the caller's cache.
    private static func nearest(_ v: SIMD3<Int>, palette: [(UInt8, UInt8, UInt8)],
                                cache: inout [Int16]) -> Int {
        let key = ((v.x >> 3) << 10) | ((v.y >> 3) << 5) | (v.z >> 3)
        let cached = cache[key]
        if cached >= 0 { return Int(cached) }
        var best = 0, bestDist = Int.max
        for (i, c) in palette.enumerated() {
            let dr = v.x - Int(c.0), dg = v.y - Int(c.1), db = v.z - Int(c.2)
            let d = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; best = i }
        }
        cache[key] = Int16(best)
        return best
    }

    /// Floyd–Steinberg dither to the palette; nearest lookup accelerated by `cache`.
    private static func ditherToPalette(_ rgba: [UInt8], width: Int, height: Int,
                                        palette: [(UInt8, UInt8, UInt8)],
                                        cache: inout [Int16]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        // Diffused error in 1/16ths, all three channels in one vector. Two rows are swapped and
        // re-zeroed each scanline rather than reallocated — the previous shape allocated three
        // fresh [Int] per row, i.e. thousands of heap allocations per frame.
        let zero = SIMD3<Int>.zero
        let ceiling = SIMD3<Int>(repeating: 255)
        var err = [SIMD3<Int>](repeating: zero, count: width + 2)
        var next = [SIMD3<Int>](repeating: zero, count: width + 2)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let src = SIMD3<Int>(Int(rgba[o]), Int(rgba[o + 1]), Int(rgba[o + 2]))
                let v = pointwiseMin(pointwiseMax(src &+ err[x + 1] / 16, zero), ceiling)
                let idx = nearest(v, palette: palette, cache: &cache)
                out[y * width + x] = UInt8(idx)
                let c = palette[idx]
                let e = v &- SIMD3<Int>(Int(c.0), Int(c.1), Int(c.2))
                err[x + 2] &+= e &* 7
                next[x] &+= e &* 3
                next[x + 1] &+= e &* 5
                next[x + 2] &+= e
            }
            swap(&err, &next)
            for i in next.indices { next[i] = zero }
        }
        return out
    }
}
