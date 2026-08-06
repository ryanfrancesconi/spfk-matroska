// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// `sample.mkv` is `sample.mov` remuxed with `-c copy`, so its streams are bit-identical to the
/// `.mov`'s and every expectation here is independently checkable with
/// `ffprobe -show_streams sample.mkv`.
@Suite(.tags(.file), .serialized)
final class MatroskaFileTests {
    let mkv = TestBundleResources.shared.sample_mkv

    @Test func readsSegmentHeaders() throws {
        let file = try MatroskaFile(url: mkv)

        #expect(file.docType == .matroska)
        #expect(file.title == "SPFK Sample Matroska")
        #expect(file.timecodeScale == 1_000_000)

        // 2.066s, driven by the audio track outrunning the 2.048s of video.
        let duration = try #require(file.duration)
        #expect(abs(duration - 2.066) < 0.001)
    }

    @Test func readsBothTracks() throws {
        let file = try MatroskaFile(url: mkv)

        #expect(file.tracks.count == 2)
        #expect(file.tracks.map(\.number) == [1, 2])
        #expect(file.videoTrack?.codecID == "V_MPEG4/ISO/AVC")
        #expect(file.audioTrack?.codecID == "A_AAC")
        #expect(file.track(number: 2)?.number == 2)
    }

    @Test func readsVideoParameters() throws {
        let file = try MatroskaFile(url: mkv)
        let track = try #require(file.videoTrack)

        guard case let .video(parameters) = track.kind else {
            Issue.record("expected a video track kind")
            return
        }

        // 160x120 is deliberately non-square in aspect, so an axis swap would show up here.
        #expect(parameters.pixelWidth == 160)
        #expect(parameters.pixelHeight == 120)
        #expect(track.displaySize == CGSize(width: 160, height: 120))

        let frameRate = try #require(track.frameRate)
        #expect(abs(frameRate - 30) < 0.001)
    }

    @Test func readsAudioParameters() throws {
        let file = try MatroskaFile(url: mkv)
        let track = try #require(file.audioTrack)

        guard case let .audio(parameters) = track.kind else {
            Issue.record("expected an audio track kind")
            return
        }

        #expect(parameters.sampleRate == 44100)
        #expect(parameters.channelCount == 1)
    }

    /// The whole reason the demuxer is worth having: `CodecPrivate` is what a format description is
    /// built from, so a track that parses without it is useless downstream.
    @Test func readsCodecPrivateAsAVCConfiguration() throws {
        let file = try MatroskaFile(url: mkv)

        let avcC = try #require(file.videoTrack?.codecPrivate)
        #expect(avcC.count == 30)

        // configurationVersion, the first byte of an AVCDecoderConfigurationRecord -- proves this
        // is the avcC blob verbatim rather than some re-wrapped payload.
        #expect(avcC.first == 0x01)

        // AudioSpecificConfig for mono 44.1 kHz AAC-LC.
        let asc = try #require(file.audioTrack?.codecPrivate)
        #expect(asc.count == 2)
    }

    @Test func rejectsANonMatroskaFile() {
        let mov = TestBundleResources.shared.sample_mov

        #expect(throws: MatroskaError.notMatroska(mov)) {
            try MatroskaFile(url: mov)
        }
    }

    @Test func rejectsAMissingFile() {
        let missing = URL(fileURLWithPath: "/nonexistent/absent.mkv")

        #expect(throws: MatroskaError.unreadableFile(missing)) {
            try MatroskaFile(url: missing)
        }
    }
}
