// Copyright Ryan Francesconi. All Rights Reserved.

import AudioToolbox
import CoreMedia
import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// The feed a player pulls from.
@Suite(.tags(.file), .serialized)
struct MatroskaSampleBufferReaderTests {
    private let mkv = TestBundleResources.shared.sample_mkv
    private let mka = TestBundleResources.shared.sample_mka
    private let webm = TestBundleResources.shared.sample_webm

    /// Reads the whole file in batches, accumulating both tracks.
    private func readAll(url: URL, batchSize: Int = 32) throws -> (video: [CMSampleBuffer], audio: [CMSampleBuffer]) {
        let reader = try MatroskaSampleBufferReader(url: url)

        var video: [CMSampleBuffer] = []
        var audio: [CMSampleBuffer] = []

        while true {
            let batch = try reader.next(upTo: batchSize)
            video += batch.video
            audio += batch.audio
            if batch.isEndOfFile { break }
        }

        return (video, audio)
    }

    /// One walk yields both tracks, and every frame in the file is accounted for — 149 across the
    /// two, which is what `ffprobe -show_packets` counts.
    @Test func oneWalkYieldsBothTracks() throws {
        let (video, audio) = try readAll(url: mkv)

        #expect(video.count == 60)
        #expect(audio.count == 89)
    }

    /// The tracks arrive interleaved rather than one after the other — the property that lets a
    /// player feed two renderers without seeking. Audio for the first second must show up while
    /// video for the first second is still coming.
    @Test func tracksArriveInterleavedNotSequentially() throws {
        let reader = try MatroskaSampleBufferReader(url: mkv)

        let batch = try reader.next(upTo: 24)

        #expect(batch.video.isEmpty == false)
        #expect(batch.audio.isEmpty == false)
        #expect(batch.isEndOfFile == false)
    }

    /// Reading past the end keeps answering "end", rather than throwing or restarting — a feed loop
    /// that races one extra batch must not be punished for it.
    @Test func readingPastTheEndStaysAtTheEnd() throws {
        let reader = try MatroskaSampleBufferReader(url: mkv)

        while try reader.next(upTo: 64).isEndOfFile == false {}

        let extra = try reader.next(upTo: 8)
        #expect(extra.isEmpty)
        #expect(extra.isEndOfFile)
    }

    /// Stored order, not presentation order — the property the display path depends on. Sorting the
    /// timestamps must still recover the whole track, which is what says nothing was dropped.
    @Test func videoArrivesInStoredOrderCoveringTheWholeTrack() throws {
        let timestamps = try readAll(url: mkv).video.map(\.presentationTimeStamp.seconds)

        #expect(timestamps != timestamps.sorted())

        let sorted = timestamps.sorted()
        #expect(abs((sorted.first ?? 0) - 0.048) < 0.001)
        #expect(abs((sorted.last ?? 0) - 2.015) < 0.001)
    }

    /// Audio has no reordering to do, so unlike video it must come out already ascending.
    @Test func audioArrivesInPresentationOrder() throws {
        let timestamps = try readAll(url: mkv).audio.map(\.presentationTimeStamp.seconds)

        #expect(timestamps.isEmpty == false)
        #expect(timestamps == timestamps.sorted())
    }

    // MARK: - Format descriptions

    /// The magic cookie is what makes AAC decodable: Matroska's `CodecPrivate` is the
    /// AudioSpecificConfig verbatim, and without it a renderer has a sample rate and nothing to
    /// decode with.
    @Test func theAudioFormatDescriptionCarriesTheCodecPrivateAsItsMagicCookie() throws {
        let reader = try MatroskaSampleBufferReader(url: mkv)

        let description = try #require(reader.audioFormatDescription)
        let track = try #require(reader.audioTrack)
        let codecPrivate = try #require(track.codecPrivate)

        #expect(codecPrivate.isEmpty == false)

        var cookieSize: Int = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize)

        #expect(cookie != nil)
        #expect(cookieSize == codecPrivate.count)

        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        // Cross-checked against `ffprobe`: mono AAC at 44100.
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 44100)
        #expect(asbd.mChannelsPerFrame == 1)
        #expect(asbd.mFramesPerPacket == 1024)
    }

    /// A codec macOS cannot decode must not stop the picture. `sample.webm` carries Opus, which is
    /// outside the table, so the audio track is dropped and video still opens.
    @Test func anUndescribableAudioTrackDoesNotFailTheOpen() throws {
        let reader = try MatroskaSampleBufferReader(url: webm)

        #expect(reader.audioTrack == nil)
        #expect(reader.audioFormatDescription == nil)

        let batch = try reader.next(upTo: 16)
        #expect(batch.video.isEmpty == false)
        #expect(batch.audio.isEmpty)
    }

    // MARK: - Seeking

    /// Seeking mid-file must resume on a keyframe, or the layer starts decoding without references.
    @Test func seekingResumesFromAKeyframe() throws {
        let reader = try MatroskaSampleBufferReader(url: mkv)
        try reader.seek(to: 1.5)

        let batch = try reader.next(upTo: 8)
        let first = try #require(batch.video.first)

        #expect(first.presentationTimeStamp.seconds <= 1.5)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(first, createIfNecessary: false)
        let notSync = (attachments as? [[CFString: Any]])?.first?[kCMSampleAttachmentKey_NotSync]
        #expect(notSync == nil)
    }

    @Test func refusesAFileWithNoVideoTrack() {
        #expect(throws: MatroskaVideoDecoderError.noVideoTrack(mka)) {
            try MatroskaSampleBufferReader(url: mka)
        }
    }
}
