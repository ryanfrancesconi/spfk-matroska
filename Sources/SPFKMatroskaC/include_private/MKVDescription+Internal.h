// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

// ObjC++ -- names mkvparser types, so it can only be imported from a .mm.

#import <Foundation/Foundation.h>

#import "MKVSegmentDescription.h"
#import "MKVTrackDescription.h"

#import <mkvparser/mkvparser.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts a parser-owned C string, which is NULL for any element the file omits.
NSString *_Nullable MKVStringOrNil(const char *_Nullable value);

@interface MKVTrackDescription ()
- (instancetype)initWithTrack:(const mkvparser::Track *)track;
@end

@interface MKVSegmentDescription ()
- (instancetype)initWithDocType:(NSString *)docType
                           info:(const mkvparser::SegmentInfo *)info
                         tracks:(NSArray<MKVTrackDescription *> *)tracks;
@end

NS_ASSUME_NONNULL_END
