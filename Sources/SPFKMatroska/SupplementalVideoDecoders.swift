// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation
import VideoToolbox

/// The decoders macOS ships but does not load into a process that has not asked for them.
///
/// VP9 is the case that matters: unregistered, `VTDecompressionSessionCreate` answers
/// `kVTCouldNotFindVideoDecoderErr` for every WebM and `VTIsHardwareDecodeSupported` reports
/// `false` — which reads as a machine with no VP9 hardware rather than a decoder nobody asked for.
/// Registering flips both.
///
/// Process-global and idempotent, so any number of callers may ask.
public enum SupplementalVideoDecoders {
    /// AV1 is asked for alongside VP9: it registers nothing on a machine without a decoder, and is
    /// correct on one that has it.
    private static let codecs: [CMVideoCodecType] = [kCMVideoCodecType_VP9, kCMVideoCodecType_AV1]

    /// Registers on the first call and does nothing thereafter.
    ///
    /// Measured 2026-08-10: 0.007 ms for the first call, 0.00004 ms for each after — cheap enough
    /// to call on any path that is about to build a decoder.
    public static func register() {
        _ = registered
    }

    // No macOS clause: the API is macOS 11+ and this package's floor is 13. iOS gained it only in
    // 26.2, well above the declared floor.
    private static let registered: Bool = {
        if #available(iOS 26.2, *) {
            for codec in codecs {
                VTRegisterSupplementalVideoDecoderIfAvailable(codec)
            }
        }
        return true
    }()
}
