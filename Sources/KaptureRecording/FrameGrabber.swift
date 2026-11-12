// One frame of a movie as a still, at the movie's native pixel size.
import AVFoundation
import CoreGraphics

public enum FrameGrabber {
    /// The frame displayed at `time`: the frame with the latest presentation time at or before it.
    ///
    /// The poster decoders elsewhere accept the nearest keyframe, which can be up to the
    /// recorder's 1.5s keyframe interval away. A grab must return the frame the player shows,
    /// so both tolerances are zero. `duration` is the movie's, which the caller's player item
    /// already holds.
    public static func frame(of asset: AVAsset, at time: CMTime, duration: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // At the end of the movie the player reports a time equal to the duration. No frame is
        // displayed at that instant. The last frame is displayed through the millisecond before.
        let end = duration - CMTime(value: 1, timescale: 1000)
        let requested = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, end: end))
        return try await generator.image(at: requested).image
    }
}
