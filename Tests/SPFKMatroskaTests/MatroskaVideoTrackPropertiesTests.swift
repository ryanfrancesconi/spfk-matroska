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

    /// Duration is the *segment's*, an upper bound on the video track's, because Matroska states no
    /// per-track duration. Measured against the `.mov` it was remuxed from rather than asserted
    /// away: the video track is exactly 2.0s (60 frames at 30fps) while the segment runs to 2.066s,
    /// the extra 66ms being the audio track's tail. Roughly two frames, so the gap is real and
    /// worth knowing before anything starts computing with this value.
    @Test func durationIsTheSegmentsNotTheVideoTracks() async throws {
        let properties = try #require(try MatroskaFile(url: mkv).videoTrackProperties)
        let duration = try #require(properties.duration)

        #expect(abs(duration - 2.066) < 0.001)

        let reference = try #require(await VideoTrackReader.read(from: mov).videoTrack?.duration)
        #expect(abs(reference - 2.0) < 0.001)
        #expect(duration > reference)
    }

    /// `preciseFrameRate` needs the exact rational frame duration and `rotationDegrees` needs the
    /// `Projection` element; neither is read yet, and a guess is worse than a blank.
    @Test func leavesUnknowableFieldsNil() throws {
        let properties = try #require(try MatroskaFile(url: mkv).videoTrackProperties)

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

    // MARK: - readAnyContainer

    /// The shared entry point every call site uses. Three of them exist across the two products,
    /// and the one that kept calling plain `read(from:)` is what left TorchTag's rows blank.
    @Test func readAnyContainerFillsInMatroska() async throws {
        let result = await VideoTrackReader.readAnyContainer(from: mkv)
        let videoTrack = try #require(result.videoTrack)

        #expect(videoTrack.width == 160)
        #expect(videoTrack.codec == "avc1")

        // Still unplayable -- the demuxer supplies properties, not playback, and the row's status
        // indicator must keep saying so.
        #expect(result.isPlayable == false)

        // No Matroska equivalent, so not invented.
        #expect(result.quickTimeUserData == nil)
    }

    /// A container AVFoundation *can* open must not be diverted — same values as the plain read,
    /// including the QuickTime user data the Matroska path has no way to produce.
    @Test func readAnyContainerLeavesAVFoundationFormatsAlone() async throws {
        let plain = await VideoTrackReader.read(from: mov)
        let any = await VideoTrackReader.readAnyContainer(from: mov)

        #expect(any.videoTrack == plain.videoTrack)
        #expect(any.isPlayable == plain.isPlayable)
        #expect(any.quickTimeUserData != nil)
        #expect(any.quickTimeUserData == plain.quickTimeUserData)
    }

    /// Asking about a file that is neither playable video nor Matroska is allowed and answers nil,
    /// rather than logging a failure for every such file.
    @Test func readAnyContainerReturnsNilForANonVideoFile() async {
        let result = await VideoTrackReader.readAnyContainer(from: TestBundleResources.shared.tabla_wav)
        #expect(result.videoTrack == nil)
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
