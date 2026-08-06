// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// Every expectation here comes from `ffprobe -show_packets` on the same file, not from reading the
/// implementation back to itself:
///
///     ffprobe -v error -show_packets -of csv=p=0 \
///       -show_entries packet=stream_index,pts_time,size,flags sample.mkv
///
/// ffprobe's stream 0 is Matroska `TrackNumber` 1 (video) and stream 1 is `TrackNumber` 2 (audio) —
/// ffprobe indexes from zero, Matroska numbers from one.
@Suite(.tags(.file), .serialized)
final class MatroskaFrameReaderTests {
    let mkv = TestBundleResources.shared.sample_mkv
    let mka = TestBundleResources.shared.sample_mka

    static let videoTrack = 1
    static let audioTrack = 2

    // MARK: - Counts and payloads

    /// 149 packets, 60 video and 89 audio. A demuxer that drops laced frames or stops at the first
    /// cluster still produces plausible-looking output, so the count is the first thing to pin.
    @Test func emitsEveryPacketFfprobeSees() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames()

        #expect(frames.count == 149)
        #expect(frames.filter { $0.trackNumber == Self.videoTrack }.count == 60)
        #expect(frames.filter { $0.trackNumber == Self.audioTrack }.count == 89)
    }

    /// Total payload bytes per track, which catches an off-by-one in the lacing header far more
    /// reliably than a frame count does — a wrong offset still yields the right number of frames.
    @Test func payloadBytesMatchFfprobe() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames()

        let video = frames.filter { $0.trackNumber == Self.videoTrack }
        let audio = frames.filter { $0.trackNumber == Self.audioTrack }

        #expect(video.reduce(0) { $0 + $1.data.count } == 3091)
        #expect(audio.reduce(0) { $0 + $1.data.count } == 356)
    }

    // MARK: - Ordering and timing

    /// Frames come back in stored order, interleaved across tracks — that is what a player consumes
    /// and what makes playback possible without seeking.
    @Test func emitsFramesInMuxedOrder() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames().prefix(6)

        let actual = frames.map { ($0.trackNumber, Int(($0.timestamp * 1000).rounded()), $0.data.count, $0.isKeyframe) }
        let expected: [(Int, Int, Int, Bool)] = [
            (1, 48, 145, true),
            (2, 0, 4, true),
            (1, 181, 51, false),
            (2, 23, 4, true),
            (2, 47, 4, true),
            (1, 115, 33, false),
        ]

        #expect(actual.count == expected.count)

        for (index, pair) in zip(actual, expected).enumerated() {
            #expect(pair.0 == pair.1, "frame \(index)")
        }
    }

    /// **Video timestamps are not monotonic in stored order, and that is correct.** Matroska stores
    /// presentation time with no container-level decode timestamp, so a stream with B-frames is
    /// stored out of presentation order — third packet at 181ms before the fourth at 115ms. A
    /// demuxer "fixing" this by sorting would break decode order.
    @Test func videoTimestampsAreNotMonotonicBecauseOfBFrames() throws {
        let video = try MatroskaFrameReader(url: mkv)
            .allFrames(ofTrack: Self.videoTrack)
            .map(\.timestamp)

        #expect(video.count == 60)
        #expect(zip(video, video.dropFirst()).contains { $0 > $1 })

        // Audio has no reordering, so it is monotonic — the contrast is the point.
        let audio = try MatroskaFrameReader(url: mkv)
            .allFrames(ofTrack: Self.audioTrack)
            .map(\.timestamp)

        #expect(zip(audio, audio.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func timestampRangesMatchFfprobe() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames()

        let video = frames.filter { $0.trackNumber == Self.videoTrack }.map(\.timestamp)
        let audio = frames.filter { $0.trackNumber == Self.audioTrack }.map(\.timestamp)

        #expect(abs((video.min() ?? 0) - 0.048) < 0.001)
        #expect(abs((video.max() ?? 0) - 2.015) < 0.001)
        #expect(abs((audio.min() ?? -1) - 0.0) < 0.001)
        #expect(abs((audio.max() ?? 0) - 2.043) < 0.001)
    }

    // MARK: - Keyframes

    /// 4 video keyframes, matching the fixture's keyframe-every-15-frames GOP, and every audio
    /// frame a keyframe as AAC always is. Seeking depends on this flag, so a demuxer reporting all
    /// frames as keyframes would look fine until the first seek landed on garbage.
    @Test func keyframeFlagsMatchFfprobe() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames()

        let video = frames.filter { $0.trackNumber == Self.videoTrack }
        let audio = frames.filter { $0.trackNumber == Self.audioTrack }

        let videoKeyframes = video.filter { $0.isKeyframe }.count
        let everyAudioFrameIsAKeyframe = audio.allSatisfy { $0.isKeyframe }

        #expect(videoKeyframes == 4)
        #expect(everyAudioFrameIsAKeyframe)
    }

    /// `CodecPrivate` describes the stream; the first keyframe is the first thing a decoder is fed
    /// after it. Pinning its exact size catches a walk that starts mid-cluster.
    @Test func theFirstVideoFrameIsAKeyframeOfTheExpectedSize() throws {
        let first = try #require(try MatroskaFrameReader(url: mkv).allFrames(ofTrack: Self.videoTrack).first)

        #expect(first.isKeyframe)
        #expect(first.data.count == 145)
        #expect(abs(first.timestamp - 0.048) < 0.001)
    }

    // MARK: - Frame duration

    /// Duration comes from the track's `DefaultDuration`, which is the only place this file states
    /// one — 1/30s for video. Audio states none, so it is nil rather than zero.
    @Test func frameDurationComesFromTheTrackDefault() throws {
        let frames = try MatroskaFrameReader(url: mkv).allFrames()

        let video = try #require(frames.first { $0.trackNumber == Self.videoTrack })
        let duration = try #require(video.duration)
        #expect(abs(duration - 1.0 / 30.0) < 0.0005)
    }

    // MARK: - Other containers

    /// The audio-only container walks the same way, with no video track to interleave.
    @Test func walksAnAudioOnlyFile() throws {
        let frames = try MatroskaFrameReader(url: mka).allFrames()

        let everyFrameIsAKeyframe = frames.allSatisfy { $0.isKeyframe }

        #expect(frames.isEmpty == false)
        #expect(Set(frames.map(\.trackNumber)).count == 1)
        #expect(everyFrameIsAKeyframe)
    }

    /// The reader exposes the headers it already parsed, so consuming frames does not mean opening
    /// the file a second time to find out what they are.
    @Test func exposesTheHeadersWithoutASecondOpen() throws {
        let reader = try MatroskaFrameReader(url: mkv)

        #expect(reader.file.docType == .matroska)
        #expect(reader.file.tracks.count == 2)
        #expect(reader.file.videoTrack?.codecID == "V_MPEG4/ISO/AVC")
    }

    @Test func rejectsANonMatroskaFile() {
        let mov = TestBundleResources.shared.sample_mov

        #expect(throws: MatroskaError.notMatroska(mov)) {
            try MatroskaFrameReader(url: mov)
        }
    }

    /// Reading past the end returns nil rather than throwing — a clean end is not a failure.
    @Test func returnsNilPastTheEndOfTheFile() throws {
        let reader = try MatroskaFrameReader(url: mkv)

        while try reader.nextFrame() != nil {}

        let afterEnd = try reader.nextFrame()
        let afterEndAgain = try reader.nextFrame()

        #expect(afterEnd == nil)
        #expect(afterEndAgain == nil)
    }
}
