// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import SPFKVideo
import Testing

@testable import SPFKMatroska

@Suite(.tags(.file), .serialized)
final class MatroskaVideoTrackPropertiesTests {
    let mkv = TestBundleResources.shared.sample_mkv
    let webm = TestBundleResources.shared.sample_webm
    let mka = TestBundleResources.shared.sample_mka
    let mov = TestBundleResources.shared.sample_mov

    /// The one that matters: `sample.mkv` is `sample.mov` remuxed with `-c copy`, so the streams
    /// are bit-identical and the demuxer must agree with AVFoundation field for field. Checked
    /// against the reference implementation rather than against numbers written here by hand.
    @Test func agreesWithAVFoundationOnTheSameStream() async throws {
        let reference = try #require(await VideoTrackReader.read(from: mov).videoTrack)
        let demuxed = try #require(try MatroskaFile(url: mkv).videoTrackProperties)

        #expect(demuxed.width == reference.width)
        #expect(demuxed.height == reference.height)
        #expect(demuxed.codec == reference.codec)
        #expect(demuxed.pixelAspectRatio == reference.pixelAspectRatio)

        let demuxedRate = try #require(demuxed.nominalFrameRate)
        let referenceRate = try #require(reference.nominalFrameRate)
        #expect(abs(demuxedRate - referenceRate) < 0.001)
    }

    @Test func populatesResolutionAndCodecForMatroska() throws {
        let properties = try #require(try MatroskaFile(url: mkv).videoTrackProperties)

        // The gap this closes: a .mkv row showed a blank Resolution because AVFoundation could not
        // open the container at all.
        #expect(properties.width == 160)
        #expect(properties.height == 120)
        #expect(properties.codec == "avc1")

        // Square pixels report nil, not 1.0, matching what AVFoundation omits.
        #expect(properties.pixelAspectRatio == nil)
    }

    @Test func populatesResolutionAndCodecForWebM() throws {
        let properties = try #require(try MatroskaFile(url: webm).videoTrackProperties)

        #expect(properties.width == 160)
        #expect(properties.height == 120)
        #expect(properties.codec == "vp09")
    }

    /// Left `nil` on purpose — see `videoTrackProperties`. A plausible-looking wrong duration is
    /// worse than a blank one, since the segment duration is not the video track's.
    @Test func leavesUnknowableFieldsNil() throws {
        let properties = try #require(try MatroskaFile(url: mkv).videoTrackProperties)

        #expect(properties.duration == nil)
        #expect(properties.preciseFrameRate == nil)
        #expect(properties.rotationDegrees == nil)
    }

    @Test func hasNoVideoPropertiesForAnAudioOnlyFile() throws {
        #expect(try MatroskaFile(url: mka).videoTrackProperties == nil)
    }

    /// A codec with no CoreMedia equivalent yields `nil` rather than a made-up code, so a caller
    /// can tell "unsupported" from "unread".
    @Test func reportsNilForACodecWithNoCoreMediaEquivalent() throws {
        let track = try #require(try MatroskaFile(url: mkv).videoTrack)
        #expect(track.codecFourCC == "avc1")

        let audio = try #require(try MatroskaFile(url: mka).audioTrack)
        #expect(audio.codecFourCC == nil)
    }

    /// `DisplayWidth`/`DisplayHeight` are only a resolution when `DisplayUnit` says pixels, and
    /// ffmpeg writes `4` here — outside the set this package models — alongside display dimensions
    /// that happen to match the pixel ones. So the unit is genuinely read rather than defaulted
    /// (mkvparser defaults it to 0), and anything unmodeled falls back to the pixel dimensions
    /// instead of trusting values whose unit is not known to be pixels.
    @Test func readsDisplayUnit() throws {
        let track = try #require(try MatroskaFile(url: mkv).videoTrack)

        guard case let .video(parameters) = track.kind else {
            Issue.record("expected a video track kind")
            return
        }

        #expect(parameters.displayWidth == 160)
        #expect(parameters.displayHeight == 120)
        #expect(parameters.displayUnit == .other(4))
        #expect(track.displaySize == CGSize(width: 160, height: 120))
    }
}
