// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import <Foundation/Foundation.h>

#import "MKVFrame.h"
#import "MKVSegmentDescription.h"

NS_ASSUME_NONNULL_BEGIN

/// Walks a Matroska file's frames in stored (muxed) order, one at a time.
///
/// Clusters are parsed lazily as the walk reaches them rather than indexed up front, so opening a
/// long file costs the front of it and memory grows with what has been read rather than with the
/// file's length.
///
/// Frames arrive interleaved across tracks exactly as the muxer wrote them, which is the order a
/// player wants: audio and video for the same instant are adjacent, so playback needs no seeking
/// and no buffering of one track while scanning for the other.
@interface MKVFrameReader : NSObject

/// Opens the file and parses its headers. Fails for the same reasons `MKVDemuxer` does.
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;

/// The headers, so a caller does not have to open the file twice to get both.
@property (nonatomic, readonly) MKVSegmentDescription *segmentDescription;

/// The next frame, or `nil` at end of stream **or** on failure.
///
/// Check ``failure`` to tell those apart: it is nil at a clean end of stream. Split this way
/// because an ObjC method returning a nullable object plus an `NSError **` imports into Swift as
/// `throws` returning non-optional, which cannot express "no more frames" without inventing an
/// error for the ordinary end of a file.
- (nullable MKVFrame *)nextFrame;

/// The error that stopped the walk, or nil if it ran to a clean end.
@property (nonatomic, readonly, nullable) NSError *failure;

@end

NS_ASSUME_NONNULL_END
