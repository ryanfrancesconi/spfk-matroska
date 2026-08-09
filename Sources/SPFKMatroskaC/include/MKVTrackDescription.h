// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Matroska `TrackType` values, matching `mkvparser::Track::Type`.
typedef NS_ENUM(NSInteger, MKVTrackType) {
    MKVTrackTypeUnknown = 0,
    MKVTrackTypeVideo = 1,
    MKVTrackTypeAudio = 2,
    MKVTrackTypeSubtitle = 0x11,
    MKVTrackTypeMetadata = 0x21,
};

/// One `TrackEntry` from a Matroska file's `Tracks` element.
///
/// Deliberately flat: video and audio parameters sit side by side rather than in subclasses, and
/// the unrelated half reads as zero. This is a transport type across the ObjC++ boundary and
/// nothing else -- `MatroskaTrack` on the Swift side models the same data as a sum type, which is
/// what callers should be using.
@interface MKVTrackDescription : NSObject

@property(nonatomic, readonly) long long number;

/// `TrackUID` -- the identity a file keeps across a remux, where ``number`` is positional and does
/// not. What a persisted track selection must be keyed on.
@property(nonatomic, readonly) unsigned long long uid;

@property(nonatomic, readonly) MKVTrackType type;

/// The Matroska `CodecID`, e.g. `V_MPEG4/ISO/AVC` or `A_AAC`. Required by the spec, so a file
/// missing it is malformed rather than merely undescribed.
@property(nonatomic, readonly, copy, nullable) NSString *codecID;
@property(nonatomic, readonly, copy, nullable) NSString *codecName;
@property(nonatomic, readonly, copy, nullable) NSString *name;
@property(nonatomic, readonly, copy, nullable) NSString *language;

/// `CodecPrivate` -- the codec's out-of-band setup data. For H.264 this is the `avcC` blob
/// verbatim, which is exactly what `CMVideoFormatDescription` wants.
@property(nonatomic, readonly, copy, nullable) NSData *codecPrivate;

/// Nanoseconds per frame, or 0 when the file does not state it.
@property(nonatomic, readonly) unsigned long long defaultDuration;

// MARK: - Video, zero unless type == MKVTrackTypeVideo

@property(nonatomic, readonly) long long pixelWidth;
@property(nonatomic, readonly) long long pixelHeight;

/// Display dimensions, which encode aspect ratio and need not match the pixel dimensions.
/// Meaningful as pixels only when ``displayUnit`` says so.
@property(nonatomic, readonly) long long displayWidth;
@property(nonatomic, readonly) long long displayHeight;

/// What ``displayWidth``/``displayHeight`` are measured in: `DisplayUnit`, where 0 is pixels,
/// 1 centimeters, 2 inches and 3 a display aspect ratio. Reading the display dimensions as
/// pixels without checking this is wrong for every value but 0.
@property(nonatomic, readonly) long long displayUnit;

/// `FrameRate`, a deprecated Matroska element that most muxers omit -- 0 is the common case, and
/// ``defaultDuration`` is the reliable source. Reported as-is rather than derived so the caller
/// can tell "absent" from "computed".
@property(nonatomic, readonly) double frameRate;

// MARK: - Audio, zero unless type == MKVTrackTypeAudio

@property(nonatomic, readonly) double sampleRate;
@property(nonatomic, readonly) long long channelCount;
@property(nonatomic, readonly) long long bitDepth;

@end

NS_ASSUME_NONNULL_END
