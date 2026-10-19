// Checks the hardware H.264 encoder before a recording starts.
//
// The hardware encoder can stop accepting work while the rest of the system runs normally: on
// macOS 27.0.1 after twelve days of uptime, every hardware session failed its first frame with
// -17691 (the AVE driver reported error 0xfffffc0d), and AVAssetWriter failed the same way on
// every frame. The recording ran to the end and produced no movie. Probing first means the
// person learns this before recording rather than after. A restart clears it.
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum EncoderProbe {
    /// The hardware H.264 encoder is not accepting frames.
    public struct Unavailable: LocalizedError {
        public var errorDescription: String? {
            "The video encoder isn't responding. Restart the Mac to record."
        }
    }

    /// Encodes one blank frame on the hardware H.264 encoder and reports whether it came back.
    /// A failing encoder fails the first frame, so one is enough; it costs a few milliseconds.
    public static func hardwareEncodes(width: Int, height: Int) -> Bool {
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
}

/// The probe's output handler runs before `VTCompressionSessionCompleteFrames` returns, on
/// VideoToolbox's thread, so it reports through a reference rather than a captured variable.
private final class ProbeResult: @unchecked Sendable {
    var encoded = false
}
