// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import AudioToolbox
import CoreMedia
import Foundation

/// A Matroska audio `CodecID` macOS has a decoder for.
///
/// Deliberately a small set. Matroska admits codecs macOS cannot decode (DTS and TrueHD among
/// them), and a caller needs "cannot decode this" to be an answer rather than silence.
///
/// Lives here rather than beside either consumer because there are now two — the PCM decoder in
/// `spfk-audio-conversion` and the sample-buffer path in this package — and a codec table with two
/// copies is a codec table that drifts.
public enum MatroskaAudioCodec: String, Sendable, CaseIterable {
    case aac = "A_AAC"
    case mp3 = "A_MPEG/L3"
    case ac3 = "A_AC3"
    case flac = "A_FLAC"
    case pcmIntegerLittleEndian = "A_PCM/INT/LIT"

    public var formatID: AudioFormatID {
        switch self {
        case .aac: kAudioFormatMPEG4AAC
        case .mp3: kAudioFormatMPEGLayer3
        case .ac3: kAudioFormatAC3
        case .flac: kAudioFormatFLAC
        case .pcmIntegerLittleEndian: kAudioFormatLinearPCM
        }
    }

    /// Frames per compressed packet, which a decoder needs up front because a compressed format
    /// cannot state bytes-per-frame.
    ///
    /// Zero for the formats that state it themselves. AAC is the LC figure; a HE-AAC stream doubles
    /// it through SBR, which the magic cookie describes rather than this.
    public var framesPerPacket: UInt32 {
        switch self {
        case .aac: 1024
        case .mp3: 1152
        case .ac3: 1536
        case .flac, .pcmIntegerLittleEndian: 0
        }
    }

    /// Whether the decoder needs this track's `CodecPrivate` as a magic cookie.
    ///
    /// For AAC that blob *is* the AudioSpecificConfig Core Audio wants, and for FLAC the STREAMINFO
    /// block — the same "stored verbatim, no conversion" property the video side relies on for
    /// `avcC`. MP3 and AC-3 describe themselves in every frame header and carry none.
    public var usesCodecPrivateAsMagicCookie: Bool {
        switch self {
        case .aac, .flac: true
        case .mp3, .ac3, .pcmIntegerLittleEndian: false
        }
    }
}
