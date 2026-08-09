// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import SPFKVideo
import SwiftTimecode
import Testing

@testable import SPFKMatroska

/// Whether a `.mkv` can render timecode, which needs a standard frame rate resolved from what the
/// container states.
@Suite(.tags(.file), .serialized)
final class MatroskaTimecodeFrameRateTests {
    /// **`preciseFrameRate` is nil here and always will be** — it is AVFoundation's exact rational
    /// match, and AVFoundation cannot open this container. A caller reading it instead of
    /// `timecodeFrameRate` gets no timecode for any Matroska file.
    @Test func statesNoPreciseRateButStillResolvesOne() throws {
        let properties = try #require(
            MatroskaFile.videoTrackProperties(for: TestBundleResources.shared.sample_mkv)
        )

        #expect(properties.preciseFrameRate == nil)
        #expect(properties.timecodeFrameRate == .fps30)
    }

    /// `DefaultDuration` is whole nanoseconds, so 30fps is stored as 33333333ns and is not exactly
    /// 1/30. The tolerant match is what makes it resolve anyway.
    @Test func resolvesARateFromAWholeNanosecondFrameDuration() throws {
        let file = try MatroskaFile(url: TestBundleResources.shared.sample_mkv)
        let track = try #require(file.videoTrack)

        let nanoseconds = try #require(track.defaultFrameDurationNanoseconds)
        #expect(Double(nanoseconds) != 1_000_000_000.0 / 30)

        let rate = try #require(track.frameRate)
        #expect(abs(rate - 30) < 0.001)
    }

    /// The dual-audio fixture carries the same rate, so a file with several audio tracks does not
    /// confuse the video track's rate read.
    @Test func resolvesTheRateOnAMultiTrackFile() throws {
        let properties = try #require(
            MatroskaFile.videoTrackProperties(for: TestBundleResources.shared.sample_dualaudio_mkv)
        )

        #expect(properties.timecodeFrameRate == .fps30)
    }
}
