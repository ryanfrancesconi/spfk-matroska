// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import <Foundation/Foundation.h>

#import "MKVTrackDescription.h"

NS_ASSUME_NONNULL_BEGIN

/// A Matroska file's `Segment` header: everything readable without walking clusters.
@interface MKVSegmentDescription : NSObject

/// The EBML `DocType` -- `matroska` or `webm`. WebM is a Matroska profile, so both parse
/// identically; this only says which one the muxer declared.
@property (nonatomic, readonly, copy) NSString *docType;

@property (nonatomic, readonly, copy, nullable) NSString *title;
@property (nonatomic, readonly, copy, nullable) NSString *muxingApp;
@property (nonatomic, readonly, copy, nullable) NSString *writingApp;

/// Nanoseconds per timecode unit -- 1,000,000 (millisecond resolution) in practice. Every raw
/// timecode in the file is in these units.
@property (nonatomic, readonly) long long timecodeScale;

/// Total duration in nanoseconds, or 0 when the file does not state one. Live/streamed captures
/// legitimately omit it, so 0 means "unknown", not "empty".
@property (nonatomic, readonly) long long durationNanoseconds;

@property (nonatomic, readonly, copy) NSArray<MKVTrackDescription *> *tracks;

@end

NS_ASSUME_NONNULL_END
