// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One compressed frame, still encoded — this package demuxes and never decodes.
@interface MKVFrame : NSObject

/// The `TrackNumber` this frame belongs to, matching `MKVTrackDescription.number`.
@property (nonatomic, readonly) long long trackNumber;

/// The compressed payload, exactly as stored.
@property (nonatomic, readonly, copy) NSData *data;

/// Presentation timestamp in nanoseconds from the start of the segment.
///
/// Matroska stores presentation time directly and has no separate decode timestamp — a decoder
/// reorders using the codec's own information rather than a container-level DTS. So for a stream
/// with B-frames these timestamps are **not** monotonic in stored order, which is correct and not
/// a parse error.
@property (nonatomic, readonly) long long timestampNanoseconds;

/// Frame duration in nanoseconds, from the track's `DefaultDuration`, or 0 when the file states
/// none. Matroska rarely carries a per-block duration.
@property (nonatomic, readonly) long long durationNanoseconds;

/// Whether the frame can be decoded without reference to another — a `SimpleBlock` keyframe flag,
/// or a `BlockGroup` with no `ReferenceBlock`.
@property (nonatomic, readonly) BOOL isKeyframe;

@end

NS_ASSUME_NONNULL_END
