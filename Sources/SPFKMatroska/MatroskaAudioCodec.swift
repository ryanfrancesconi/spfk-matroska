// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation

/// A Matroska audio `CodecID` macOS has a decoder for.
///
/// Deliberately small: Matroska admits codecs macOS cannot decode, DTS and TrueHD among them, and
/// a caller needs that to be an answer rather than silence. Shared by both consumers, since a codec
/// table with two copies drifts.
public enum MatroskaAudioCodec: String, Sendable, CaseIterable {
    case aac = "A_AAC"
    case mp3 = "A_MPEG/L3"
    case ac3 = "A_AC3"
    case flac = "A_FLAC"
    case opus = "A_OPUS"
    case pcmIntegerLittleEndian = "A_PCM/INT/LIT"
    case pcmIntegerBigEndian = "A_PCM/INT/BIG"
    case pcmFloat = "A_PCM/FLOAT/IEEE"

    public var formatID: AudioFormatID {
        switch self {
        case .aac: kAudioFormatMPEG4AAC
        case .mp3: kAudioFormatMPEGLayer3
        case .ac3: kAudioFormatAC3
        case .flac: kAudioFormatFLAC
        case .opus: kAudioFormatOpus
        case .pcmIntegerLittleEndian, .pcmIntegerBigEndian, .pcmFloat: kAudioFormatLinearPCM
        }
    }

    /// Frames per compressed packet where the codec fixes it, and zero where it does not.
    ///
    /// AAC is the LC figure; a HE-AAC stream doubles it through SBR, which the magic cookie
    /// describes rather than this. **FLAC is zero because its figure belongs to the file rather than
    /// to the codec** — ``MatroskaTrack/audioFramesPerPacket`` reads it from STREAMINFO. **Opus is
    /// zero because it belongs to the packet**: each one states its own frame size in its TOC byte,
    /// and a stream may mix 2.5 ms through 60 ms freely.
    public var framesPerPacket: UInt32 {
        switch self {
        case .aac: 1024
        case .mp3: 1152
        case .ac3: 1536
        case .flac, .opus, .pcmIntegerLittleEndian, .pcmIntegerBigEndian, .pcmFloat: 0
        }
    }

    /// How a PCM track's samples are laid out, or `nil` for a compressed codec.
    ///
    /// Signedness is not here because it follows the bit depth rather than the CodecID: Matroska
    /// inherits WAV's rule that 8-bit integer samples are unsigned and wider ones signed.
    public var pcmSampleFormat: MatroskaPCMSampleFormat? {
        switch self {
        case .pcmIntegerLittleEndian: .integer(isBigEndian: false)
        case .pcmIntegerBigEndian: .integer(isBigEndian: true)
        case .pcmFloat: .float
        case .aac, .mp3, .ac3, .flac, .opus: nil
        }
    }

    /// Whether the decoder takes this track's `CodecPrivate` as a magic cookie.
    ///
    /// For AAC that blob *is* the AudioSpecificConfig Core Audio wants, the same "stored verbatim"
    /// property `avcC` has on the video side. MP3, AC-3 and PCM carry none. FLAC's STREAMINFO is
    /// accepted but not needed: what a FLAC track decodes on is the source-depth flag and packet
    /// length in ``MatroskaTrack/makeAudioStreamBasicDescription()``, not this.
    ///
    /// **Opus carries an `OpusHead` and Core Audio does not read it.** Measured 2026-08-10: decoding
    /// with the cookie and without produced byte-identical output, at both a stated and an unstated
    /// packet length. It is left out rather than passed on the chance it helps, because a cookie the
    /// decoder does not expect is a way to be refused. The one thing `OpusHead` states that goes
    /// unapplied is the pre-skip — see ``MatroskaTrack/opusPreSkipFrames``.
    public var usesCodecPrivateAsMagicCookie: Bool {
        switch self {
        case .aac, .flac: true
        case .mp3, .ac3, .opus, .pcmIntegerLittleEndian, .pcmIntegerBigEndian, .pcmFloat: false
        }
    }
}

/// How a Matroska PCM track's samples are stored.
public enum MatroskaPCMSampleFormat: Hashable, Sendable {
    case integer(isBigEndian: Bool)

    /// IEEE 754, little endian — the only byte order Matroska defines for float PCM.
    case float
}
