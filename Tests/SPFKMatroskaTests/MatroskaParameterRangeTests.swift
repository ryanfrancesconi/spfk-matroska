// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// A corrupt or crafted file can state sizes and rates libwebm accepts but Core Media cannot take.
@Suite(.tags(.file), .serialized)
final class MatroskaParameterRangeTests {
    @Test func outOfRangeValuesReadAsZero() {
        for rate in [Double.infinity, .nan, 5e9] {
            #expect(MatroskaTrack.AudioParameters(sampleRate: rate, channelCount: 2, bitDepth: nil).sampleRate == 0)
        }

        #expect(MatroskaTrack.AudioParameters(sampleRate: 48000, channelCount: Int(UInt32.max) + 1, bitDepth: nil).channelCount == 0)

        let video = MatroskaTrack.VideoParameters(
            pixelWidth: Int(Int32.max) + 1,
            pixelHeight: 48,
            displayWidth: 0,
            displayHeight: 0,
            displayUnit: .pixels,
            declaredFrameRate: nil
        )

        #expect(video.pixelWidth == 0)
        #expect(video.pixelHeight == 48)
    }

    @Test func anInfiniteSampleRateIsRefused() {
        let track = MatroskaTrack(
            number: 1,
            uid: 1,
            kind: .audio(.init(sampleRate: .infinity, channelCount: 2, bitDepth: nil)),
            codecID: "A_AAC",
            codecName: nil,
            name: nil,
            language: nil,
            codecPrivate: nil,
            defaultFrameDurationNanoseconds: nil
        )

        #expect(throws: MatroskaSampleBufferError.missingAudioParameters) {
            try track.makeAudioStreamBasicDescription()
        }
    }

    /// The picture still plays when the audio track states an impossible rate. libwebm refuses a
    /// non-finite float outright, so the largest finite case is what reaches the reader.
    @Test func aFileWithAnImpossibleSampleRatePlaysWithoutItsAudio() throws {
        let source = TestBundleResources.shared.sample_mkv
        let rate = try #require(try MatroskaFile(url: source).audioTrack.flatMap { track -> Double? in
            if case let .audio(parameters) = track.kind { parameters.sampleRate } else { nil }
        })

        // `SamplingFrequency` (0xB5) with a size of 8, then the rate as a big-endian double.
        let element = Data([0xB5, 0x88]) + withUnsafeBytes(of: rate.bitPattern.bigEndian) { Data($0) }
        let replacement = Data([0xB5, 0x88]) + withUnsafeBytes(of: (5e9 as Double).bitPattern.bigEndian) { Data($0) }

        var data = try Data(contentsOf: source)
        let range = try #require(data.range(of: element))
        data.replaceSubrange(range, with: replacement)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spfk-matroska-rate-\(UUID().uuidString).mkv")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MatroskaSampleBufferReader.canOpen(url: url))
        #expect(try MatroskaSampleBufferReader(url: url).audioTrack == nil)
    }

    @Test func aVideoTrackTooWideForCoreMediaIsNotDecodable() throws {
        let file = MatroskaTestFile(
            tracks: [.video(number: 1, uid: 1, codecID: "V_VP9", width: 1 << 31, height: 48)],
            clusters: [.init(timecode: 0, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 16)])])]
        )

        let url = try file.writeTemporary()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MatroskaVideoDecoder.posterCGImage(url: url) == nil)
        #expect(try MatroskaFile(url: url).videoTrack?.isDecodable == false)
    }
}
