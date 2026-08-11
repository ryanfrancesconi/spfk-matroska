// Copyright Ryan Francesconi. All Rights Reserved.

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
    ///
    /// **Strictly** ascending, which is the part that matters. Matroska laces several audio frames
    /// into one block and stores a single timestamp for it, so a reader that reports the block's
    /// time for each of them hands a renderer a pile of packets all claiming the same instant —
    /// audible as a stutter, and invisible to any check that only asks whether the list is sorted.
    ///
    /// Verified against a real laced file (`DualAudio` anime rips lace; a WEBRip typically does
    /// not): before the fix its first eight audio packets all read 0.009, after it they step by
    /// 21.333 ms, matching `ffprobe`. The fixtures here are unlaced, so this test pins the
    /// invariant rather than the lacing arithmetic.
    @Test func audioArrivesInStrictlyIncreasingOrder() throws {
        let timestamps = try readAll(url: mkv).audio.map(\.presentationTimeStamp.seconds)

        #expect(timestamps.isEmpty == false)
        #expect(timestamps == timestamps.sorted())

        let duplicates = zip(timestamps, timestamps.dropFirst()).filter { $0 >= $1 }
        #expect(duplicates.isEmpty)
    }

    /// Audio packets sit on the codec's own grid, not the container's.
    ///
    /// Matroska quantizes block timestamps to `TimecodeScale` — a millisecond — and no compressed
    /// packet length divides that evenly, so reading times straight out of the container gives a
    /// sawtooth: an AAC packet is 23.22 ms at 44.1 kHz, stored as alternating 23 and 24. Measured
    /// on two real films, the spacing is now exact to the sample across 400+ packets where it
    /// previously deviated by up to half a millisecond every packet.
    @Test func audioPacketsAreSpacedOnTheCodecGrid() throws {
        let timestamps = try readAll(url: mkv).audio.map(\.presentationTimeStamp)

        #expect(timestamps.count > 8)

        // 1024 frames per AAC packet at the fixture's 44100 Hz.
        let expected = 1024.0 / 44100.0
        let deltas = zip(timestamps, timestamps.dropFirst()).map { ($1 - $0).seconds }

        let offGrid = deltas.filter { abs($0 - expected) > 0.000_001 }
        #expect(offGrid.isEmpty)
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

    /// WebM's Opus track is described and fed alongside the picture, which is what gives a `.webm`
    /// sound in TorchTag. Core Audio decodes Opus — it is in
    /// `kAudioFormatProperty_DecodeFormatIDs` — so no bundled library is involved.
    ///
    /// **The tolerance this used to cover — an undescribable audio track being dropped rather than
    /// failing the open — no longer has a committed fixture**, because every bundled Matroska now
    /// carries a codec in the table. Vorbis is the remaining undescribable case and its fixture is
    /// scratch. The behavior itself is unchanged in `MatroskaSampleBufferReader.init`.
    @Test func theWebMOpusTrackIsDescribedAndDelivered() throws {
        let reader = try MatroskaSampleBufferReader(url: webm)

        let track = try #require(reader.audioTrack)
        #expect(track.codecID == "A_OPUS")
        #expect(reader.audioFormatDescription != nil)

        let batch = try reader.next(upTo: 16)
        #expect(batch.video.isEmpty == false)
        #expect(batch.audio.isEmpty == false)
    }

    /// **Every audio buffer must carry numeric timing, or the renderer silently drops all of them.**
    /// Matroska states no block duration, so a buffer that falls back to container timing gets an
    /// invalid one and `AVSampleBufferAudioRenderer` refuses it with
    /// `kCMSampleBufferError_SampleTimingInfoInvalid` (-12740) — the picture plays and the file is
    /// mute, which reads as a decoder problem and is not one.
    ///
    /// Asserted for both codecs: AAC has a fixed packet length and Opus states one per packet, and
    /// only the fixed case worked when this was written.
    @Test(arguments: [TestBundleResources.shared.sample_mkv, TestBundleResources.shared.sample_webm])
    func everyAudioBufferCarriesNumericTiming(url: URL) throws {
        let reader = try MatroskaSampleBufferReader(url: url)
        let batch = try reader.next(upTo: 64)

        #expect(batch.audio.isEmpty == false)

        for buffer in batch.audio {
            let duration = CMSampleBufferGetDuration(buffer)
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer)

            #expect(duration.isNumeric, "non-numeric duration \(duration)")
            #expect(presentationTime.isNumeric, "non-numeric pts \(presentationTime)")
            #expect(duration.seconds > 0)
        }
    }

    /// Opus packet lengths come from each packet rather than a track-level figure, and this file
    /// mixes them — 501 packets decode to 480,840 frames where a uniform 960 would give 480,960.
    @Test func opusPacketLengthsAreReadFromEachPacket() throws {
        let track = try #require(try MatroskaFile(url: webm).audioTrack)

        #expect(track.audioFramesPerPacket == nil, "Opus has no fixed track-level length")

        let reader = try MatroskaFrameReader(url: webm)
        var counts: Set<Int> = []

        while let frame = try reader.nextFrame() {
            guard frame.trackNumber == track.number, frame.data.isEmpty == false else { continue }
            counts.insert(try #require(track.audioFrameCount(forPacket: frame.data)))
        }

        #expect(counts.isEmpty == false)
        // 20 ms at 48 kHz is what a WebM muxer writes by default.
        #expect(counts.contains(960), "packet lengths seen: \(counts.sorted())")
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
