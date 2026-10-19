// Which H.264 encoder a recording uses, decided once per recording before capture starts.
//
// The hardware encoder can stop accepting work while the rest of the system runs normally: on
// macOS 27.0.1 after twelve days of uptime, every hardware session failed its first frame with
// -17691 (the AVE driver reported error 0xfffffc0d), and AVAssetWriter failed the same way, so
// every recording was lost. The software encoder still worked. It encodes about 120 fps at
// 1080p but 13 fps at 6K on an M2 Ultra, so a software recording is captured at most
// `softwareMaxEdge` on its long side, which it encodes at about 60 fps.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoEncoder: Equatable, Sendable {
    case hardware
    case software

    public static let softwareMaxEdge = 2560

    /// The hardware encoder when it encodes a frame at this size, otherwise the software one.
    public static func choose(width: Int, height: Int) -> VideoEncoder {
        hardwareEncodes(width: width, height: height) ? .hardware : .software
    }

    /// Encodes one blank frame on the hardware H.264 encoder and reports whether it came back.
    /// A failing encoder fails the first frame, so one is enough; it costs a few milliseconds.
    static func hardwareEncodes(width: Int, height: Int) -> Bool {
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created) == noErr,
              let session = created else { return false }
        defer { VTCompressionSessionInvalidate(session) }

        var frame: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes,
                                  &frame) == kCVReturnSuccess, let frame else { return false }

        let result = ProbeResult()
        let submitted = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: .zero, duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            result.encoded = status == noErr && sample != nil
        }
        guard submitted == noErr else { return false }
        // Returns once the frame's output handler has run.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return result.encoded
    }

    /// The size to capture and encode at: the requested size on hardware; on software, scaled so
    /// the long edge is at most `softwareMaxEdge`, with even dimensions as H.264 requires.
    public func size(width: Int, height: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard self == .software, longEdge > Self.softwareMaxEdge else { return (width, height) }
        let scale = Double(Self.softwareMaxEdge) / Double(longEdge)
        let even = { (value: Int) in max(2, Int((Double(value) * scale).rounded()) / 2 * 2) }
        return (even(width), even(height))
    }

    /// `AVVideoEncoderSpecificationKey` for the writer. Hardware leaves the choice to
    /// AVFoundation, as before; software rules the hardware encoder out.
    public var specification: [String: Any] {
        switch self {
        case .hardware: return [:]
        case .software:
            return [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        }
    }
}

/// The probe's output handler runs before `VTCompressionSessionCompleteFrames` returns, on
/// VideoToolbox's thread, so it reports through a reference rather than a captured variable.
private final class ProbeResult: @unchecked Sendable {
    var encoded = false
}
