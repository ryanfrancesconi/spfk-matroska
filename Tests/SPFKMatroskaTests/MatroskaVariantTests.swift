// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// The two container shapes `sample.mkv` cannot cover: WebM, and audio with no video track at all.
@Suite(.tags(.file), .serialized)
final class MatroskaVariantTests {
    let webm = TestBundleResources.shared.sample_webm
    let mka = TestBundleResources.shared.sample_mka

    // MARK: - WebM

    /// The whole justification for choosing libwebm's parser: WebM is a Matroska profile, so one
    /// parser covers both and the `DocType` is the only thing that differs.
    @Test func readsWebMThroughTheSameParser() throws {
        let file = try MatroskaFile(url: webm)

        #expect(file.docType == .webm)
        #expect(file.title == "SPFK Sample WebM")
        #expect(file.tracks.count == 2)
        #expect(file.videoTrack?.codecID == "V_VP9")
        #expect(file.audioTrack?.codecID == "A_OPUS")

        let duration = try #require(file.duration)
        #expect(abs(duration - 2.026) < 0.001)
    }

    @Test func readsWebMVideoParameters() throws {
        let file = try MatroskaFile(url: webm)
        let track = try #require(file.videoTrack)

        guard case let .video(parameters) = track.kind else {
            Issue.record("expected a video track kind")
            return
        }

        // Same framing as the H.264 original, so a container-specific dimension bug shows up as a
        // difference against `sample.mkv` rather than as a plausible-looking number.
        #expect(parameters.pixelWidth == 160)
        #expect(parameters.pixelHeight == 120)

        let frameRate = try #require(track.frameRate)
        #expect(abs(frameRate - 30) < 0.001)
    }

    /// VP9 needs no out-of-band setup data and carries none, where H.264 carries an `avcC`. A
    /// format-description path that assumes every video track has `CodecPrivate` breaks here.
    @Test func webMVideoTrackHasNoCodecPrivate() throws {
        let file = try MatroskaFile(url: webm)

        #expect(file.videoTrack?.codecPrivate == nil)

        // Opus does carry one -- an OpusHead -- so absence is a per-codec fact, not a WebM one.
        let opusHead = try #require(file.audioTrack?.codecPrivate)
        #expect(opusHead.count == 19)
        #expect(opusHead.prefix(8) == Data("OpusHead".utf8))
    }

    @Test func readsWebMAudioParameters() throws {
        let file = try MatroskaFile(url: webm)
        let track = try #require(file.audioTrack)

        guard case let .audio(parameters) = track.kind else {
            Issue.record("expected an audio track kind")
            return
        }

        // 48 kHz rather than the source's 44.1: Opus has one native rate and encoding resamples.
        #expect(parameters.sampleRate == 48000)
        #expect(parameters.channelCount == 1)
    }

    // MARK: - Audio-only Matroska

    @Test func readsAudioOnlyMatroska() throws {
        let file = try MatroskaFile(url: mka)

        #expect(file.docType == .matroska)
        #expect(file.title == "SPFK Sample Matroska Audio")
        #expect(file.tracks.count == 1)

        // The case a video-bearing fixture cannot reach: nothing to find, rather than the wrong
        // thing found.
        #expect(file.videoTrack == nil)

        let track = try #require(file.audioTrack)
        #expect(track.codecID == "A_AAC")

        guard case let .audio(parameters) = track.kind else {
            Issue.record("expected an audio track kind")
            return
        }

        // Copied from `sample.mov` rather than re-encoded, so these match it exactly.
        #expect(parameters.sampleRate == 44100)
        #expect(parameters.channelCount == 1)
        #expect(track.codecPrivate?.count == 2)
    }

    /// `displaySize` and `frameRate` are video questions, and both should decline to answer rather
    /// than inventing a zero.
    @Test func audioOnlyTrackReportsNoVideoGeometry() throws {
        let file = try MatroskaFile(url: mka)
        let track = try #require(file.audioTrack)

        #expect(track.displaySize == nil)
        #expect(track.frameRate == nil)
    }
}
