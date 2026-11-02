// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreAudioTypes
import Foundation

/// The channel configuration and length an AC-3 or E-AC-3 syncframe states in its header.
///
/// A channel count does not determine an AC-3 layout except at 1 and 6: four channels can be
/// 3/1, 2/2 or 3/0 + LFE. Every syncframe states its own, and Matroska carries no other record of it.
public struct MatroskaAC3Header: Hashable, Sendable {
    /// Whether this is an E-AC-3 frame (`bsid` 11–16) rather than AC-3 (`bsid` 0–10).
    public let isEnhanced: Bool

    /// The audio coding mode: front and surround channels, A/52 Table 5.8. 0 is two independent
    /// mono programs.
    public let audioCodingMode: Int

    public let hasLFE: Bool

    /// Audio blocks of 256 frames each. Always 6 for AC-3; 1, 2, 3 or 6 for E-AC-3.
    public let blockCount: Int

    /// Reads the header at the start of `frame`, or `nil` when it is not a syncframe or is too short
    /// to hold the fields.
    public init?(frame: Data) {
        // The furthest field read is AC-3's `lfeon`, at most bit 55.
        guard frame.count >= 7 else { return nil }

        let bytes = [UInt8](frame.prefix(7))

        guard bytes[0] == 0x0B, bytes[1] == 0x77 else { return nil }

        let bitstreamID = Int(bytes[5] >> 3)

        if bitstreamID <= 10 {
            isEnhanced = false
            blockCount = 6

            var reader = BitReader(bytes: bytes, bitOffset: 48)
            let mode = reader.read(3)

            if mode & 1 != 0, mode != 1 { _ = reader.read(2) } // cmixlev
            if mode & 4 != 0 { _ = reader.read(2) } // surmixlev
            if mode == 2 { _ = reader.read(2) } // dsurmod

            audioCodingMode = mode
            hasLFE = reader.read(1) == 1

        } else if bitstreamID <= 16 {
            isEnhanced = true

            let sampleRateCode = bytes[4] >> 6
            let blockCode = Int((bytes[4] >> 4) & 0b11)

            // With `fscod` 3 the two bits are a reduced-rate code and the frame has six blocks.
            blockCount = sampleRateCode == 3 ? 6 : [1, 2, 3, 6][blockCode]
            audioCodingMode = Int((bytes[4] >> 1) & 0b111)
            hasLFE = bytes[4] & 1 == 1

        } else {
            return nil
        }
    }

    /// Frames each packet decodes to.
    public var framesPerPacket: Int { blockCount * 256 }

    /// Channels the header describes, counting the LFE.
    public var channelCount: Int {
        let fullBandwidth = [2, 1, 2, 3, 3, 4, 4, 5][audioCodingMode]
        return fullBandwidth + (hasLFE ? 1 : 0)
    }

    /// The layout Core Audio's decoder outputs for this configuration, or `nil` for one not yet
    /// measured — dual mono, 2/1 and 2/2 + LFE among them.
    public var channelLayoutTag: AudioChannelLayoutTag? {
        switch (audioCodingMode, hasLFE) {
        case (1, false): kAudioChannelLayoutTag_Mono
        case (2, false): kAudioChannelLayoutTag_Stereo
        case (2, true): kAudioChannelLayoutTag_DVD_4
        case (3, false): kAudioChannelLayoutTag_AC3_3_0
        case (3, true): kAudioChannelLayoutTag_AC3_3_0_1
        case (5, false): kAudioChannelLayoutTag_AC3_3_1
        case (5, true): kAudioChannelLayoutTag_AC3_3_1_1
        case (6, false): kAudioChannelLayoutTag_ITU_2_2
        case (7, false): kAudioChannelLayoutTag_MPEG_5_0_C
        case (7, true): kAudioChannelLayoutTag_MPEG_5_1_C
        default: nil
        }
    }
}

/// Reads big-endian bit fields, returning zeros past the end.
private struct BitReader {
    let bytes: [UInt8]
    var bitOffset: Int

    mutating func read(_ count: Int) -> Int {
        var value = 0

        for _ in 0 ..< count {
            let byte = bitOffset / 8
            let bit = byte < bytes.count ? (bytes[byte] >> (7 - bitOffset % 8)) & 1 : 0
            value = value << 1 | Int(bit)
            bitOffset += 1
        }

        return value
    }
}
